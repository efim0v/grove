import Foundation
import GroveCore

// Pure presentation logic for the code-stats screen (Stage 4). No SwiftUI, no I/O —
// every model below is built from an already-scanned `CodeStats` / `CodeStatsPoint`
// history (and a `DirNode` skeleton for the exclusion tree) and is fully
// unit-testable, mirroring DashboardPresentation. The stats screen renders these.

// MARK: - Language bars (one row per language)

/// One language's row in the breakdown. `fraction` is this language's `code`
/// relative to the BUSIEST language's code (0…1), so the view draws bars on a
/// shared axis. The formatted strings keep number formatting out of the view.
public struct LanguageBar: Equatable, Sendable, Identifiable {
    public var id: String { language }
    public let language: String
    public let code: Int
    public let comment: Int
    public let blank: Int
    public let files: Int
    public let fraction: Double          // 0…1 of the max code across languages
    public let codeText: String          // "12.5k"
    public let commentText: String       // "1.2k"
    public let blankText: String         // "840"
    public let filesText: String         // "384"

    public init(language: String, code: Int, comment: Int, blank: Int, files: Int, fraction: Double) {
        self.language = language
        self.code = code
        self.comment = comment
        self.blank = blank
        self.files = files
        self.fraction = fraction
        self.codeText = formatCompactTokens(code)
        self.commentText = formatCompactTokens(comment)
        self.blankText = formatCompactTokens(blank)
        self.filesText = formatCompactTokens(files)
    }
}

/// Build one bar per language. Input is already sorted DESC by code
/// (`CodeStats.byLanguage`'s contract), so the output preserves that order;
/// `fraction` is each language's code over the largest language's code.
public func languageBars(_ stats: CodeStats) -> [LanguageBar] {
    let maxCode = stats.byLanguage.map(\.code).max() ?? 0
    return stats.byLanguage.map { l in
        LanguageBar(language: l.language, code: l.code, comment: l.comment,
                    blank: l.blank, files: l.files,
                    fraction: maxCode > 0 ? Double(l.code) / Double(maxCode) : 0)
    }
}

// MARK: - Headline totals

/// The one-line headline: "12,481 lines · 384 files · 71% code". `codePercent`
/// is code over total lines (0 when empty). Grouped thousands for the human counts.
public struct StatsTotals: Equatable, Sendable {
    public let totalLines: Int
    public let totalFiles: Int
    public let codePercent: Int          // 0…100, rounded
    public let formatted: String

    public init(totalLines: Int, totalFiles: Int, codePercent: Int, formatted: String) {
        self.totalLines = totalLines
        self.totalFiles = totalFiles
        self.codePercent = codePercent
        self.formatted = formatted
    }
}

public func statsTotals(_ stats: CodeStats) -> StatsTotals {
    let percent = stats.totalLines > 0
        ? Int((Double(stats.code) / Double(stats.totalLines) * 100).rounded()) : 0
    let lines = groupedThousands(stats.totalLines)
    let files = groupedThousands(stats.totalFiles)
    return StatsTotals(totalLines: stats.totalLines, totalFiles: stats.totalFiles,
                       codePercent: percent,
                       formatted: "\(lines) lines · \(files) files · \(percent)% code")
}

/// Thousands-grouped integer: 12481 -> "12,481". Deterministic (POSIX locale).
func groupedThousands(_ n: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.usesGroupingSeparator = true
    formatter.groupingSeparator = ","
    formatter.groupingSize = 3
    return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
}

// MARK: - Exclusion tree (mark folders excluded from stats scans)

/// One row in the stats-exclusion folder picker. `relativePath` is the project-root-
/// relative directory path (the stable id AND the key written to
/// `ProjectConfig.statsIgnoredFolders`); `depth` is the indent level (root's
/// children are depth 0); `isExcluded` reflects whether this folder is currently
/// excluded — either because it is itself in `ignoredFolders`, or because an
/// ANCESTOR is (an excluded folder hides its whole subtree from the scan).
public struct StatsTreeRow: Equatable, Sendable, Identifiable {
    public var id: String { relativePath }
    public let name: String
    public let depth: Int
    public let relativePath: String
    public let isExcluded: Bool
    /// True when the exclusion is INHERITED from an excluded ancestor (so the view
    /// can show the checkbox as disabled/derived rather than a directly-set toggle).
    public let excludedByAncestor: Bool

    public init(name: String, depth: Int, relativePath: String,
                isExcluded: Bool, excludedByAncestor: Bool) {
        self.name = name
        self.depth = depth
        self.relativePath = relativePath
        self.isExcluded = isExcluded
        self.excludedByAncestor = excludedByAncestor
    }
}

/// Flatten a `DirNode` skeleton into display rows, marking each folder excluded
/// when it (or an ancestor) is in `ignoredFolders`. Pure: no I/O. The root node
/// itself is NOT emitted (it's the project, never excludable); its children start
/// at depth 0. Children are emitted depth-first in `DirNode.children` order (the
/// scanner already sorts them by name), so the rows read as an indented tree.
public func buildStatsTree(_ root: DirNode, ignoredFolders: Set<String>) -> [StatsTreeRow] {
    var rows: [StatsTreeRow] = []
    func walk(_ node: DirNode, depth: Int, ancestorExcluded: Bool) {
        for child in node.children {
            let selfExcluded = ignoredFolders.contains(child.relativePath)
            let excluded = ancestorExcluded || selfExcluded
            rows.append(StatsTreeRow(name: child.name, depth: depth,
                                     relativePath: child.relativePath,
                                     isExcluded: excluded,
                                     excludedByAncestor: ancestorExcluded))
            walk(child, depth: depth + 1, ancestorExcluded: excluded)
        }
    }
    walk(root, depth: 0, ancestorExcluded: false)
    return rows
}

// MARK: - Per-file directory tree (folders + files with summed LOC)

/// One row in the stats-settings directory+FILE tree. Folders carry a SUMMED
/// `lines` (every descendant file) and a `fileCount`; files carry their own line
/// total, a `language`, and an `isDataProse` tint flag (and no toggle). `id` is the
/// `relativePath`, which for a folder is the project-root-relative directory and for
/// a file is the full project-relative file path. `depth` indents the row;
/// `excludedByAncestor` distinguishes an inherited exclusion (disabled toggle) from a
/// directly-set one.
public struct FileTreeRow: Equatable, Sendable, Identifiable {
    public var id: String { relativePath }
    public let name: String
    public let depth: Int
    public let relativePath: String
    public let lines: Int             // summed for folders, single file for files
    public let fileCount: Int         // descendant files for folders, 1 for files
    public let isFolder: Bool
    public let isExcluded: Bool
    public let excludedByAncestor: Bool
    public let language: String?      // nil for folders
    public let isDataProse: Bool      // false for folders

    public init(name: String, depth: Int, relativePath: String, lines: Int, fileCount: Int,
                isFolder: Bool, isExcluded: Bool, excludedByAncestor: Bool,
                language: String? = nil, isDataProse: Bool = false) {
        self.name = name
        self.depth = depth
        self.relativePath = relativePath
        self.lines = lines
        self.fileCount = fileCount
        self.isFolder = isFolder
        self.isExcluded = isExcluded
        self.excludedByAncestor = excludedByAncestor
        self.language = language
        self.isDataProse = isDataProse
    }
}

/// A nested tree node for the SwiftUI `OutlineGroup`/`DisclosureGroup` rendering.
/// A folder has non-nil `children` (folders first, then files, each group sorted by
/// name); a file has `children == nil`. Carries the same display fields as
/// `FileTreeRow`. Built by `buildFileTreeNodes`; the flat `buildFileTree` is the
/// depth-first flattening of the same structure (used by unit tests).
public struct FileTreeNode: Equatable, Sendable, Identifiable {
    public var id: String { relativePath }
    public let name: String
    public let relativePath: String
    public let lines: Int
    public let fileCount: Int
    public let isFolder: Bool
    public let isExcluded: Bool
    public let excludedByAncestor: Bool
    public let language: String?
    public let isDataProse: Bool
    public let children: [FileTreeNode]?

    public init(name: String, relativePath: String, lines: Int, fileCount: Int,
                isFolder: Bool, isExcluded: Bool, excludedByAncestor: Bool,
                language: String? = nil, isDataProse: Bool = false,
                children: [FileTreeNode]? = nil) {
        self.name = name
        self.relativePath = relativePath
        self.lines = lines
        self.fileCount = fileCount
        self.isFolder = isFolder
        self.isExcluded = isExcluded
        self.excludedByAncestor = excludedByAncestor
        self.language = language
        self.isDataProse = isDataProse
        self.children = children
    }
}

/// Intermediate mutable folder used while assembling the tree from a flat file list.
private final class _FolderBuilder {
    let path: String              // project-relative dir ("" for the synthetic root)
    var subfolders: [String: _FolderBuilder] = [:]   // child dir name -> builder
    var files: [StatFileEntry] = []                  // files directly in this dir
    init(path: String) { self.path = path }
}

/// Group a flat `[StatFileEntry]` into a folder tree, then flatten DEPTH-FIRST into
/// display rows: each folder row is followed by its SUBFOLDERS (sorted by name) and
/// then its files (sorted by name) recursively — folders-first then files at every
/// level, so the list reads as an indented tree and matches `buildFileTreeNodes` /
/// the spec. Folder `lines`/`fileCount` are SUMMED over every descendant file. A
/// folder is `isExcluded` when it (or any ancestor) is in `ignoredFolders`; its
/// files/subfolders inherit that with `excludedByAncestor`. PURE: no I/O.
public func buildFileTree(files: [StatFileEntry], ignoredFolders: Set<String>) -> [FileTreeRow] {
    let root = _assembleFolderTree(files: files)
    var rows: [FileTreeRow] = []
    func walk(_ folder: _FolderBuilder, depth: Int, ancestorExcluded: Bool) {
        let selfExcluded = !folder.path.isEmpty && ignoredFolders.contains(folder.path)
        let excluded = ancestorExcluded || selfExcluded
        // Emit the folder row (the synthetic root is never emitted).
        if !folder.path.isEmpty {
            let (lines, count) = _folderTotals(folder)
            rows.append(FileTreeRow(
                name: _leafName(folder.path), depth: depth, relativePath: folder.path,
                lines: lines, fileCount: count, isFolder: true,
                isExcluded: excluded, excludedByAncestor: ancestorExcluded))
        }
        let childDepth = folder.path.isEmpty ? 0 : depth + 1
        // Subfolders first (sorted), then files (sorted) — folders-first, matching
        // `buildFileTreeNodes` and the spec.
        for sub in folder.subfolders.values.sorted(by: { _leafName($0.path) < _leafName($1.path) }) {
            walk(sub, depth: childDepth, ancestorExcluded: excluded)
        }
        for file in folder.files.sorted(by: { _leafName($0.path) < _leafName($1.path) }) {
            rows.append(FileTreeRow(
                name: _leafName(file.path), depth: childDepth, relativePath: file.path,
                lines: file.lines, fileCount: 1, isFolder: false,
                isExcluded: excluded, excludedByAncestor: excluded,
                language: file.language, isDataProse: file.isDataProse))
        }
    }
    walk(root, depth: 0, ancestorExcluded: false)
    return rows
}

/// The nested-node form of `buildFileTree`, for `OutlineGroup`/`DisclosureGroup`
/// (lazy disclosure). Children are folders-first then files, each sorted by name.
/// PURE: no I/O.
public func buildFileTreeNodes(files: [StatFileEntry], ignoredFolders: Set<String>) -> [FileTreeNode] {
    let root = _assembleFolderTree(files: files)
    func build(_ folder: _FolderBuilder, ancestorExcluded: Bool) -> FileTreeNode {
        let selfExcluded = !folder.path.isEmpty && ignoredFolders.contains(folder.path)
        let excluded = ancestorExcluded || selfExcluded
        var children: [FileTreeNode] = []
        // Subfolders first (sorted), then files (sorted).
        for sub in folder.subfolders.values.sorted(by: { _leafName($0.path) < _leafName($1.path) }) {
            children.append(build(sub, ancestorExcluded: excluded))
        }
        for file in folder.files.sorted(by: { _leafName($0.path) < _leafName($1.path) }) {
            children.append(FileTreeNode(
                name: _leafName(file.path), relativePath: file.path, lines: file.lines,
                fileCount: 1, isFolder: false, isExcluded: excluded,
                excludedByAncestor: excluded, language: file.language,
                isDataProse: file.isDataProse, children: nil))
        }
        let (lines, count) = _folderTotals(folder)
        return FileTreeNode(
            name: _leafName(folder.path), relativePath: folder.path, lines: lines,
            fileCount: count, isFolder: true, isExcluded: excluded,
            excludedByAncestor: ancestorExcluded, children: children)
    }
    // The synthetic root is not emitted; return its children as the top-level nodes.
    let rootNode = build(root, ancestorExcluded: false)
    return rootNode.children ?? []
}

/// Assemble the synthetic-root folder tree from a flat file list, creating every
/// intermediate folder along each file's path.
private func _assembleFolderTree(files: [StatFileEntry]) -> _FolderBuilder {
    let root = _FolderBuilder(path: "")
    for file in files {
        let comps = file.path.split(separator: "/").map(String.init)
        guard !comps.isEmpty else { continue }
        var folder = root
        var prefix = ""
        // Walk/create each intermediate folder (all components except the last = file).
        for comp in comps.dropLast() {
            prefix = prefix.isEmpty ? comp : prefix + "/" + comp
            if let existing = folder.subfolders[comp] {
                folder = existing
            } else {
                let made = _FolderBuilder(path: prefix)
                folder.subfolders[comp] = made
                folder = made
            }
        }
        folder.files.append(file)
    }
    return root
}

/// Summed (lines, fileCount) over a folder and all its descendants.
private func _folderTotals(_ folder: _FolderBuilder) -> (lines: Int, fileCount: Int) {
    var lines = folder.files.reduce(0) { $0 + $1.lines }
    var count = folder.files.count
    for sub in folder.subfolders.values {
        let (l, c) = _folderTotals(sub)
        lines += l; count += c
    }
    return (lines, count)
}

/// Last `/`-separated component of a path ("" → "").
private func _leafName(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}

// MARK: - Code vs Data/Prose split (two headline numbers)

/// The Totals card's two headline numbers: "Code" lines (non-data languages) and
/// "Data/Prose" lines (Markdown/JSON/YAML/TOML), plus their file counts. Line counts
/// use each language's `total` so the headline matches the language-table rows.
public struct DataProseTotals: Equatable, Sendable {
    public let codeLines: Int
    public let dataProseLines: Int
    public let codeFiles: Int
    public let dataProseFiles: Int
    public let codeLinesText: String        // grouped thousands, e.g. "281,989"
    public let dataProseLinesText: String
    public let codeFilesText: String
    public let dataProseFilesText: String

    public init(codeLines: Int, dataProseLines: Int, codeFiles: Int, dataProseFiles: Int) {
        self.codeLines = codeLines
        self.dataProseLines = dataProseLines
        self.codeFiles = codeFiles
        self.dataProseFiles = dataProseFiles
        self.codeLinesText = groupedThousands(codeLines)
        self.dataProseLinesText = groupedThousands(dataProseLines)
        self.codeFilesText = groupedThousands(codeFiles)
        self.dataProseFilesText = groupedThousands(dataProseFiles)
    }
}

/// Partition a scan's `byLanguage` into Code vs Data/Prose using
/// `CodeStatsEngine.isDataProse`. "Lines" sums each language's `total`.
public func dataProseBreakdown(_ stats: CodeStats) -> DataProseTotals {
    var codeLines = 0, dataLines = 0, codeFiles = 0, dataFiles = 0
    for l in stats.byLanguage {
        if CodeStatsEngine.isDataProse(l.language) {
            dataLines += l.total; dataFiles += l.files
        } else {
            codeLines += l.total; codeFiles += l.files
        }
    }
    return DataProseTotals(codeLines: codeLines, dataProseLines: dataLines,
                           codeFiles: codeFiles, dataProseFiles: dataFiles)
}

// MARK: - Per-day delta series + window recompute (period selection, no re-scan)

/// One day's additions/removals (point-in-day, summed across repos). The screen sums
/// these over any window to recompute period deltas client-side.
public struct DayDelta: Equatable, Sendable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let dayAdded: Int
    public let dayRemoved: Int
    public var dayNet: Int { dayAdded - dayRemoved }

    public init(date: Date, dayAdded: Int, dayRemoved: Int) {
        self.date = date
        self.dayAdded = dayAdded
        self.dayRemoved = dayRemoved
    }
}

/// Map an aggregate history (CodeStatsPoint, oldest-first) to its per-day deltas.
public func aggregateDayDeltas(_ history: [CodeStatsPoint]) -> [DayDelta] {
    history.map { DayDelta(date: $0.date, dayAdded: $0.dayAdded, dayRemoved: $0.dayRemoved) }
}

/// Map a per-repo history (RepoHistoryPoint, oldest-first) to its per-day deltas.
public func repoDayDeltas(_ history: [RepoHistoryPoint]) -> [DayDelta] {
    history.map { DayDelta(date: $0.date, dayAdded: $0.dayAdded, dayRemoved: $0.dayRemoved) }
}

/// Sum `dayAdded`/`dayRemoved` over the inclusive date window `[start, end]`. Days
/// outside the window are ignored. `filesChanged` is 0 (not derivable client-side).
public func deltaBetween(start: Date, end: Date, dayDeltas: [DayDelta]) -> RepoDelta {
    var added = 0, removed = 0
    for d in dayDeltas where d.date >= start && d.date <= end {
        added += d.dayAdded; removed += d.dayRemoved
    }
    return RepoDelta(added: added, removed: removed, filesChanged: 0)
}

/// The Totals card's period segmented-control model (7d / 30d / 90d / All).
public enum StatsPeriod: String, CaseIterable, Identifiable, Sendable {
    case d7 = "7d"
    case d30 = "30d"
    case d90 = "90d"
    case all = "All"
    public var id: String { rawValue }
    /// Window length in days; `nil` for "All" (unbounded back to the start of history).
    public var days: Int? {
        switch self {
        case .d7: return 7
        case .d30: return 30
        case .d90: return 90
        case .all: return nil
        }
    }
    /// Window start instant: `now − days·86400`, or `.distantPast` for "All".
    public func start(now: Date) -> Date {
        guard let days else { return .distantPast }
        return now.addingTimeInterval(-Double(days) * 24 * 3600)
    }
}

/// Convenience: recompute a period delta directly from an aggregate history.
public func periodDelta(_ history: [CodeStatsPoint], period: StatsPeriod, now: Date) -> RepoDelta {
    deltaBetween(start: period.start(now: now), end: now,
                 dayDeltas: aggregateDayDeltas(history))
}

// MARK: - Delta-triangle formatting (shared by totals + repo cards)

/// A formatted ▲/▼ delta. `direction` drives the tint (.up→primary, .down→negative,
/// .flat→neutral); `label` is the display string ("▲ +1,240" / "▼ −50" / "±0").
public struct DeltaTriangle: Equatable, Sendable {
    public enum Direction: Sendable { case up, down, flat }
    public let direction: Direction
    public let label: String
    public init(direction: Direction, label: String) {
        self.direction = direction
        self.label = label
    }
}

/// Build a `DeltaTriangle` from a net line count. Positive → ▲ "+N"; negative → ▼ with
/// a U+2212 MINUS and the absolute value; zero → "±0". Counts are grouped-thousands.
public func deltaTriangle(net: Int) -> DeltaTriangle {
    if net > 0 {
        return DeltaTriangle(direction: .up, label: "▲ +\(groupedThousands(net))")
    } else if net < 0 {
        return DeltaTriangle(direction: .down, label: "▼ \u{2212}\(groupedThousands(abs(net)))")
    } else {
        return DeltaTriangle(direction: .flat, label: "±0")
    }
}

// MARK: - Honest two-sided category delta (▲ added AND ▼ removed)

/// Both sides of a category's churn over a period: ▲ added (growth) AND ▼ removed
/// (deletions), each pre-formatted. Unlike `DeltaTriangle` (a single net triangle that
/// HID the removed count and made "+X" look like net growth), this carries BOTH counts
/// so the Totals card can show the honest gross additions and deletions, classified.
/// `addedText` is "▲ +1,240" (or "±0"); `removedText` is "▼ −120" (U+2212 minus, or "±0").
public struct CategoryDelta: Equatable, Sendable {
    public let added: Int
    public let removed: Int
    public let addedText: String      // "▲ +1,240" / "±0"
    public let removedText: String    // "▼ −120"   / "±0"

    public init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
        // Format exactly like deltaTriangle: grouped thousands + U+2212 minus, "±0" when 0.
        self.addedText = added > 0 ? "▲ +\(groupedThousands(added))" : "±0"
        self.removedText = removed > 0 ? "▼ \u{2212}\(groupedThousands(removed))" : "±0"
    }
}

/// Extract the Code and Data/Prose deltas (each a `CategoryDelta` with BOTH added and
/// removed) from an aggregate history over a period. Sums the classified per-day
/// `codeAdded`/`codeRemoved`/`dataAdded`/`dataRemoved` across the window `[start, now]`.
/// Pure; used by the Totals card to show two honest triangles per headline.
public func periodDeltasByCategory(_ history: [CodeStatsPoint], period: StatsPeriod, now: Date)
    -> (code: CategoryDelta, dataProse: CategoryDelta) {
    let start = period.start(now: now)
    var codeAdded = 0, codeRemoved = 0, dataAdded = 0, dataRemoved = 0
    for point in history where point.date >= start && point.date <= now {
        codeAdded += point.codeAdded
        codeRemoved += point.codeRemoved
        dataAdded += point.dataAdded
        dataRemoved += point.dataRemoved
    }
    return (
        code: CategoryDelta(added: codeAdded, removed: codeRemoved),
        dataProse: CategoryDelta(added: dataAdded, removed: dataRemoved)
    )
}

// MARK: - Churn bars (dense, day-filled, non-cumulative)

/// One stacked churn bar: a single calendar DAY with that day's lines ADDED (blue
/// lower segment) and lines REMOVED (pink upper segment). `totalChurn = dayAdded +
/// dayRemoved` is the bar's height — this is NON-cumulative codebase activity, not the
/// running total. Days are calendar-filled (no transparent gaps): a day with no commit
/// is a zero-churn bar (`dayAdded == dayRemoved == 0`).
public struct ChurnBarPoint: Equatable, Sendable, Identifiable {
    public var id: Date { date }
    public let date: Date              // start-of-day (GMT)
    public let dayAdded: Int           // blue segment height
    public let dayRemoved: Int         // pink segment height
    public var totalChurn: Int { dayAdded + dayRemoved }

    public init(date: Date, dayAdded: Int, dayRemoved: Int) {
        self.date = date
        self.dayAdded = dayAdded
        self.dayRemoved = dayRemoved
    }
}

/// The hard cap on how many days of churn bars we ever build: 1 YEAR. Older history is
/// kept intact in the engine (so cumulative/"All" totals stay exact) but is never drawn
/// as bars — the dense daily histogram only needs the recent window. The whole 1-year
/// strip is built so the histogram is genuinely scrollable back to the cap.
public let churnBarMaxDaysBack = 365

/// How many of the most-recent churn days fill the histogram's DEFAULT viewport (~6
/// months). The full series always spans `churnBarMaxDaysBack` (1 year), so the strip
/// opens scrolled to today showing this many days and scrolls back to the remaining
/// older days within the cap. This is INDEPENDENT of the Totals 7d/30d/90d/All period —
/// the churn chart is codebase-activity-over-time, not a delta window.
public let churnDefaultVisibleDays = 180

/// Build a DENSE churn-bar series from an aggregate history, filling EVERY calendar day
/// from `daysBack` days ago through `now`'s start-of-day so there are no transparent gaps.
/// `daysBack` is clamped to the 1-year cap (`churnBarMaxDaysBack`). Days with commits carry
/// their `dayAdded`/`dayRemoved`; days with none are zero-churn bars (the view may tint
/// these gray when "show empty days" is on, else leave them empty).
///
/// This is the histogram's OWN window — independent of the Totals 7d/30d/90d/All period.
/// The view always asks for the full 1-year span (so the strip is genuinely scrollable),
/// then opens scrolled to today with ~`churnDefaultVisibleDays` filling the viewport.
///
/// NO downsampling — the calendar density (one bar per day) is the whole point of the
/// reference histogram. The cap is presentation-only: the engine's history is never
/// truncated, so the "All"-period cumulative totals elsewhere stay correct; only the
/// drawn bar window is bounded here.
public func churnBarSeries(_ history: [CodeStatsPoint], daysBack: Int, now: Date) -> [ChurnBarPoint] {
    let cal = GitStatsService.gmtCalendar
    let capped = min(max(daysBack, 0), churnBarMaxDaysBack)
    let windowStart = cal.date(byAdding: .day, value: -capped, to: now) ?? .distantPast

    // Lookup: start-of-day → (added, removed) for every history point in the window.
    var byDay: [Date: (added: Int, removed: Int)] = [:]
    for point in history where point.date >= windowStart && point.date <= now {
        let day = cal.startOfDay(for: point.date)
        let prior = byDay[day] ?? (0, 0)
        byDay[day] = (prior.added + point.dayAdded, prior.removed + point.dayRemoved)
    }

    // Fill every calendar day [windowStart, now], oldest first.
    var bars: [ChurnBarPoint] = []
    var current = cal.startOfDay(for: windowStart)
    let end = cal.startOfDay(for: now)
    guard current <= end else { return [] }
    while current <= end {
        let (added, removed) = byDay[current] ?? (0, 0)
        bars.append(ChurnBarPoint(date: current, dayAdded: added, dayRemoved: removed))
        guard let next = cal.date(byAdding: .day, value: 1, to: current) else { break }
        current = next
    }
    return bars
}

/// Period-based convenience over `churnBarSeries(_:daysBack:now:)`: the drawn window is the
/// LATER of the period's start and the 1-year cap. Retained for callers/tests that key the
/// window off a `StatsPeriod`; the live histogram uses the `daysBack:` form directly so its
/// window is decoupled from the Totals delta period.
public func churnBarSeries(_ history: [CodeStatsPoint], period: StatsPeriod, now: Date) -> [ChurnBarPoint] {
    let cal = GitStatsService.gmtCalendar
    let periodStart = period.start(now: now)
    let capStart = cal.date(byAdding: .day, value: -churnBarMaxDaysBack, to: now) ?? .distantPast
    let windowStart = max(periodStart, capStart)
    let daysBack = Int((cal.startOfDay(for: now).timeIntervalSince(cal.startOfDay(for: windowStart)) / 86_400).rounded())
    return churnBarSeries(history, daysBack: daysBack, now: now)
}

/// The peak total churn across a churn-bar series (1 floored), the denominator the
/// view normalizes every bar's height against so the tallest day fills the plot.
public func churnPeak(_ bars: [ChurnBarPoint]) -> Int {
    max(bars.map(\.totalChurn).max() ?? 0, 1)
}

/// The pixel heights of one stacked churn bar against a resolved plot `height` and a
/// shared `peak` denominator (from `churnPeak`). The bar is STACKED: `added` (blue) is
/// the LOWER segment, `removed` (pink) the UPPER, both scaled by the same factor so
/// their union is proportional to `totalChurn / peak`. A day with churn but a tiny
/// fraction still shows a ≥1px sliver per non-zero segment (like a progress bar) so a
/// real-but-small day is never invisible; a true ZERO-churn day returns (0, 0).
public struct ChurnBarHeights: Equatable, Sendable {
    public let added: CGFloat     // lower (blue) segment height in points
    public let removed: CGFloat   // upper (pink) segment height in points
    public var total: CGFloat { added + removed }
    public init(added: CGFloat, removed: CGFloat) {
        self.added = added
        self.removed = removed
    }
}

/// Resolve one churn bar's stacked segment heights. `peak` is the series-wide max total
/// churn (`churnPeak`); `height` is the plot box height. Segments scale linearly by
/// `value / peak * height`, each non-zero segment floored at 1px so it stays visible.
public func churnBarHeights(_ bar: ChurnBarPoint, peak: Int, height: CGFloat) -> ChurnBarHeights {
    let denom = CGFloat(max(peak, 1))
    func seg(_ value: Int) -> CGFloat {
        guard value > 0 else { return 0 }
        return max(CGFloat(value) / denom * height, 1)
    }
    return ChurnBarHeights(added: seg(bar.dayAdded), removed: seg(bar.dayRemoved))
}

/// The per-day tooltip for a tapped churn bar: a short date plus the honest
/// "+added / −removed" churn (U+2212 minus on the removed side). A zero-churn day reads
/// "no commits". Pure + deterministic (POSIX, GMT) so it's unit-testable.
public func churnDayReadout(_ bar: ChurnBarPoint) -> String {
    let date = churnDayDateText(bar.date)
    guard bar.totalChurn > 0 else { return "\(date) · no commits" }
    return "\(date) · +\(groupedThousands(bar.dayAdded)) \u{2212}\(groupedThousands(bar.dayRemoved))"
}

/// "Jun 14" style short date for a churn bar's GMT start-of-day. Deterministic
/// (POSIX locale, GMT) so snapshots and tests are stable.
public func churnDayDateText(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "GMT")
    f.dateFormat = "MMM d"
    return f.string(from: date)
}

// The old cumulative growth bars (BarPoint/barSeries) and their two-bar selection delta
// (BarSelectionDelta/barSelectionDelta/barSelectionReadout) were removed with the churn
// redesign — the histogram is now per-day, non-cumulative (ChurnBarPoint/churnBarSeries),
// with a single-day tap tooltip (churnDayReadout) replacing the two-bar window selection.

// MARK: - Per-repo display blocks

/// One per-repo block on the screen: name, default branch (read-only for now), total
/// LOC, and a period delta with a formatted ▲/▼ triangle.
public struct RepoCard: Equatable, Sendable, Identifiable {
    public var id: String { repoPath }
    public let repoName: String
    public let repoPath: String           // absolute repo path; keys the branch switcher
    public let defaultBranch: String      // EFFECTIVE branch (resolved or overridden)
    public let totalLines: Int
    public let totalLinesText: String
    public let delta: RepoDelta
    public let triangle: DeltaTriangle
    public init(repoName: String, repoPath: String, defaultBranch: String, totalLines: Int,
                delta: RepoDelta) {
        self.repoName = repoName
        self.repoPath = repoPath
        self.defaultBranch = defaultBranch
        self.totalLines = totalLines
        self.totalLinesText = groupedThousands(totalLines)
        self.delta = delta
        self.triangle = deltaTriangle(net: delta.net)
    }
}

/// Build the per-repo blocks, sorted by repo name. Each block's delta is recomputed for
/// `period` from that repo's per-day history (no re-scan), so switching the period
/// updates every repo in lockstep with the Totals card.
public func repoCells(_ repos: [RepoStats], period: StatsPeriod, now: Date) -> [RepoCard] {
    repos.map { repo in
        let delta = deltaBetween(start: period.start(now: now), end: now,
                                 dayDeltas: repoDayDeltas(repo.history))
        return RepoCard(repoName: repo.repoName, repoPath: repo.repoPath,
                        defaultBranch: repo.defaultBranch,
                        totalLines: repo.stats.totalLines, delta: delta)
    }
    .sorted { $0.repoName < $1.repoName }
}
