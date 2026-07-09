import Foundation
import SwiftUI
import GroveCore

// Pure presentation logic for the code-stats screen (Stage 4). No SwiftUI, no I/O —
// every model below is built from an already-scanned `CodeStats` / `CodeStatsPoint`
// history (and a `DirNode` skeleton for the exclusion tree) and is fully
// unit-testable, mirroring DashboardPresentation. The stats screen renders these.

// MARK: - Language bars (one row per language)

/// Which `LanguageStats` field drives the Languages card — the bar length, the
/// sort order, and the share. The Languages card header selector writes this; the
/// default is `.code` (the historical behavior). `rawValue` is the human label.
public enum LanguageMetric: String, CaseIterable, Identifiable, Sendable {
    case code = "Code"
    case files = "Files"
    case total = "Lines"          // code + comment + blank
    case comment = "Comment"
    case blank = "Blank"
    public var id: String { rawValue }
    /// The chosen field's value for one language.
    public func value(_ l: LanguageStats) -> Int {
        switch self {
        case .code: return l.code
        case .files: return l.files
        case .total: return l.total
        case .comment: return l.comment
        case .blank: return l.blank
        }
    }
}

/// Which cumulative quantity the "over time" growth chart plots. Only these three are
/// derivable from git history (line counts grouped by file LANGUAGE): `lines` = every
/// line (netLines), `code`/`data` = lines in code-language / data-language files.
/// Comment/Blank/Files can't be reconstructed over time (they need file CONTENT at each
/// historical commit) — they live only in the current Totals/Languages snapshot.
public enum GrowthMetric: String, CaseIterable, Identifiable, Sendable {
    case lines = "Lines"
    case code = "Code"
    case data = "Data"
    public var id: String { rawValue }
}

/// One language's row in the breakdown. `fraction` is this language's metric
/// value relative to the BUSIEST language's metric value (0…1), so the view draws
/// bars on a shared axis. `share` is this language's metric value over the SUM of
/// the metric across all languages (0…1). The formatted strings keep number
/// formatting out of the view; `metricText`/`shareText` reflect the chosen metric.
public struct LanguageBar: Equatable, Sendable, Identifiable {
    public var id: String { language }
    public let language: String
    public let code: Int
    public let comment: Int
    public let blank: Int
    public let files: Int
    public let total: Int                // code + comment + blank
    public let fraction: Double          // 0…1 of the max metric across languages
    public let metricValue: Int          // the chosen metric's raw value
    public let share: Double             // 0…1 of the summed metric across languages
    public let codeText: String          // "12.5k"
    public let commentText: String       // "1.2k"
    public let blankText: String         // "840"
    public let filesText: String         // "384"
    public let metricText: String        // the chosen metric's compact value, e.g. "12.5k"
    public let shareText: String         // "42%"

    /// Backwards-compatible initializer: the metric is `code`, so `metricValue`/
    /// `metricText` mirror code and `total` is derived from the parts. `share` is 0
    /// (callers that care pass it via the full init below). Kept so the zero-arg
    /// `languageBars(_:)` default and existing tests compile unchanged.
    public init(language: String, code: Int, comment: Int, blank: Int, files: Int, fraction: Double) {
        self.init(language: language, code: code, comment: comment, blank: blank,
                  files: files, total: code + comment + blank, fraction: fraction,
                  metricValue: code, share: 0)
    }

    /// Full initializer carrying the chosen metric's value + share so the hover
    /// overlay and bar trailing text can read them directly.
    public init(language: String, code: Int, comment: Int, blank: Int, files: Int,
                total: Int, fraction: Double, metricValue: Int, share: Double) {
        self.language = language
        self.code = code
        self.comment = comment
        self.blank = blank
        self.files = files
        self.total = total
        self.fraction = fraction
        self.metricValue = metricValue
        self.share = share
        self.codeText = formatCompactTokens(code)
        self.commentText = formatCompactTokens(comment)
        self.blankText = formatCompactTokens(blank)
        self.filesText = formatCompactTokens(files)
        self.metricText = formatCompactTokens(metricValue)
        self.shareText = "\(Int((share * 100).rounded()))%"
    }
}

/// Build one bar per language, driven by `metric` (default `.code`). Bars are
/// sorted DESC by the chosen metric (ties broken by language name for a stable,
/// deterministic order); `fraction` is each language's metric value over the
/// busiest language's, and `share` is its metric value over the summed metric. The
/// default `.code` over `CodeStats.byLanguage` (already DESC-by-code) preserves the
/// historical order and per-row text.
public func languageBars(_ stats: CodeStats, metric: LanguageMetric = .code) -> [LanguageBar] {
    let langs = stats.byLanguage
    let maxValue = langs.map { metric.value($0) }.max() ?? 0
    let sumValue = langs.reduce(0) { $0 + metric.value($1) }
    return langs
        .sorted { a, b in
            let va = metric.value(a), vb = metric.value(b)
            return va != vb ? va > vb : a.language < b.language
        }
        .map { l in
            let v = metric.value(l)
            return LanguageBar(
                language: l.language, code: l.code, comment: l.comment, blank: l.blank,
                files: l.files, total: l.total,
                fraction: maxValue > 0 ? Double(v) / Double(maxValue) : 0,
                metricValue: v,
                share: sumValue > 0 ? Double(v) / Double(sumValue) : 0)
        }
}

// MARK: - Headline totals

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

// MARK: - Period selection (window recompute, no re-scan)

/// The Totals card's period segmented-control model (7d / 30d / 90d / 180d / 360d).
/// "All" was removed — the user only wants bounded net-delta windows; the bars' visible
/// viewport still defaults to ~180 days independently of this selection.
public enum StatsPeriod: String, CaseIterable, Identifiable, Sendable {
    case d7 = "7d"
    case d30 = "30d"
    case d90 = "90d"
    case d180 = "180d"
    case d360 = "360d"
    public var id: String { rawValue }
    /// Window length in days. Always bounded now (no unbounded "All" case).
    public var days: Int {
        switch self {
        case .d7: return 7
        case .d30: return 30
        case .d90: return 90
        case .d180: return 180
        case .d360: return 360
        }
    }
    /// Window start instant: `now − days·86400`.
    public func start(now: Date) -> Date {
        now.addingTimeInterval(-Double(days) * 24 * 3600)
    }
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

/// A COMPACT `DeltaTriangle` for the Totals hero: the magnitude is rounded to whole thousands
/// with a "K" suffix once it reaches 1,000 (the user doesn't need exact churn in the delta —
/// "+11K" reads at a glance), and shown exactly below 1,000. Sign + direction are unchanged:
/// ▲ "+11K" / ▼ "−2K" / exact "+850" / "±0". Rounding is to NEAREST thousand (11,800 → 12K).
public func compactDeltaTriangle(net: Int) -> DeltaTriangle {
    let mag = abs(net)
    let num: String = mag >= 1000
        ? "\(Int((Double(mag) / 1000).rounded()))K"
        : "\(mag)"
    if net > 0 {
        return DeltaTriangle(direction: .up, label: "▲ +\(num)")
    } else if net < 0 {
        return DeltaTriangle(direction: .down, label: "▼ \u{2212}\(num)")
    } else {
        return DeltaTriangle(direction: .flat, label: "±0")
    }
}

// MARK: - Net-lines delta (cumulative-state difference, churn-free)

/// Carry-forward value of a cumulative series AS OF an instant `t`: the value of the
/// LAST point whose date is ≤ `t`, or 0 before the first point. The series must be a
/// cumulative/running total (e.g. `CodeStatsPoint.totalLines` or `RepoHistoryPoint.netLines`),
/// so this reads the codebase SIZE at `t` — not per-day activity. Points may be in any
/// order; this finds the max-dated point ≤ `t`.
private func cumulativeValue<T>(_ series: [T], asOf t: Date,
                                date: (T) -> Date, value: (T) -> Int) -> Int {
    var result = 0
    var best: Date? = nil
    for p in series {
        let d = date(p)
        guard d <= t else { continue }
        if best == nil || d > best! { best = d; result = value(p) }
    }
    return result
}

/// Net codebase growth over a period = (cumulative total AS OF now) − (cumulative total
/// AS OF the period start), read from an aggregate cumulative history
/// (`CodeStatsPoint.totalLines` is the carried-forward project size). This is a STATE
/// DIFFERENCE: a line churned 5× counts ONCE (telescoping), so it's the honest net
/// "did the codebase grow or shrink" number — not gross added/removed churn.
public func netLinesDelta(_ history: [CodeStatsPoint], period: StatsPeriod, now: Date) -> Int {
    let nowValue = cumulativeValue(history, asOf: now, date: { $0.date }, value: { $0.totalLines })
    let startValue = cumulativeValue(history, asOf: period.start(now: now),
                                     date: { $0.date }, value: { $0.totalLines })
    return nowValue - startValue
}

/// Per-repo net growth over a period from that repo's cumulative `netLines` history
/// (state difference, churn-free). Mirrors the aggregate `netLinesDelta`.
public func netLinesDelta(repo history: [RepoHistoryPoint], period: StatsPeriod, now: Date) -> Int {
    let nowValue = cumulativeValue(history, asOf: now, date: { $0.date }, value: { $0.netLines })
    let startValue = cumulativeValue(history, asOf: period.start(now: now),
                                     date: { $0.date }, value: { $0.netLines })
    return nowValue - startValue
}

/// Per-category net growth (code vs data/prose) over a period, reconstructed from the
/// classified PER-DAY churn carried on each point. The classified fields are per-day
/// (not cumulative), so we telescope them into a cumulative classified state and take
/// the state difference across the window — equivalent to summing the per-day net
/// (codeAdded − codeRemoved) over `[periodStart, now]`. This counts a churned line's NET
/// effect once per day it changed; over the whole window it telescopes to the net code /
/// data growth. The window is INCLUSIVE on both ends (`[periodStart, now]`), matching
/// `GitStatsService.delta`/`languageSplitDelta`. Returns `(code, dataProse)` net line
/// counts (may be negative).
public func netLinesDeltaByCategory(_ history: [CodeStatsPoint], period: StatsPeriod, now: Date)
    -> (code: Int, dataProse: Int) {
    let start = period.start(now: now)
    var codeNet = 0, dataNet = 0
    for point in history where point.date >= start && point.date <= now {
        codeNet += point.codeAdded - point.codeRemoved
        dataNet += point.dataAdded - point.dataRemoved
    }
    return (code: codeNet, dataProse: dataNet)
}

// MARK: - Repo scope (filter every stats block to one repo, or all)

/// The shared controls strip's repository selector model: "All repos" (`name == nil`)
/// plus one entry per repo, sorted by name (matching the per-repo blocks + legend order).
/// `id` is the selection token written by the menu (`name`, with the synthetic "" for All
/// so SwiftUI's tag is non-optional-friendly). The view reads `name` to drive the scope.
public struct RepoScopeOption: Equatable, Sendable, Identifiable {
    public var id: String { name ?? "" }
    public let name: String?      // nil == "All repos"
    public let label: String      // "All repos" / the repo name
    public init(name: String?, label: String) {
        self.name = name
        self.label = label
    }
}

/// Build the repo-selector options: "All repos" first, then each repo by name (sorted,
/// matching `repoCells`/the legend). PURE + deterministic.
public func repoScopeOptions(_ repos: [RepoStats]) -> [RepoScopeOption] {
    var options = [RepoScopeOption(name: nil, label: "All repos")]
    for name in repos.map(\.repoName).sorted() {
        options.append(RepoScopeOption(name: name, label: name))
    }
    return options
}

/// The aggregate `CodeStats` (Totals headline + Languages bars + line kinds) SCOPED to
/// the selected repo: `nil` returns the project aggregate unchanged; a repo name returns
/// that repo's own `stats` (its `byLanguage`, totals, file count). An unknown name falls
/// back to the aggregate so a stale selection can't blank the screen. PURE.
public func filterAggregateByRepo(_ aggregate: CodeStats, repos: [RepoStats],
                                  repoName: String?) -> CodeStats {
    guard let repoName, let repo = repos.first(where: { $0.repoName == repoName })
    else { return aggregate }
    return repo.stats
}

/// The aggregate per-day history (drives the Totals net-delta triangles) SCOPED to the
/// selected repo: `nil` returns the project aggregate history unchanged; a repo name
/// projects that repo's `[RepoHistoryPoint]` into the `[CodeStatsPoint]` shape the delta
/// helpers consume — `netLines` (cumulative) → `totalLines`, and the per-day classified
/// churn fields carry over verbatim, so `netLinesDelta` / `netLinesDeltaByCategory` read
/// the repo's own growth. The non-delta fields (`code`/`comment`/`blank`/`totalFiles`)
/// aren't carried per-day on a repo's history, so they're 0 here — the deltas are the
/// only consumer of this scoped series. PURE.
public func filterHistoryByRepo(_ aggregateHistory: [CodeStatsPoint], repos: [RepoStats],
                                repoName: String?) -> [CodeStatsPoint] {
    guard let repoName, let repo = repos.first(where: { $0.repoName == repoName })
    else { return aggregateHistory }
    return repo.history.map { p in
        CodeStatsPoint(date: p.date, totalLines: max(p.netLines, 0),
                       code: 0, comment: 0, blank: 0, totalFiles: 0,
                       dayAdded: p.dayAdded, dayRemoved: p.dayRemoved,
                       codeAdded: p.codeAdded, codeRemoved: p.codeRemoved,
                       dataAdded: p.dataAdded, dataRemoved: p.dataRemoved)
    }
}

/// The per-repo list (per-repo blocks + stacked growth chart + legend) SCOPED to the
/// selected repo: `nil` returns every repo unchanged; a repo name returns just that one
/// (an unknown name returns all, never an empty screen). PURE.
public func filterRepoStats(_ repos: [RepoStats], repoName: String?) -> [RepoStats] {
    guard let repoName else { return repos }
    let scoped = repos.filter { $0.repoName == repoName }
    return scoped.isEmpty ? repos : scoped
}

// MARK: - Stacked cumulative bars (codebase size over time, stacked by repo)

/// One repo's slice of a single day's stacked bar: the repo's carried-forward cumulative
/// line count (`netLines` as of that day, clamped ≥ 0) on that calendar day.
public struct StackedSegment: Equatable, Sendable {
    public let repoName: String
    public let lines: Int
    public init(repoName: String, lines: Int) {
        self.repoName = repoName
        self.lines = lines
    }
}

/// One calendar day's stacked bar: the TOTAL codebase size across all repos that day,
/// split into one segment per repo. `segments` are sorted BIGGEST-FIRST (the view stacks
/// them bottom-up, so the biggest repo sits at the bottom; ties broken by repoName for
/// determinism), and repos with 0 lines that day are dropped. `total` is the sum — the
/// bar's height. The series GROWS left→right as the cumulative per-repo `netLines` rise.
public struct StackedDayBar: Equatable, Sendable, Identifiable {
    public var id: Date { date }
    public let date: Date                 // start-of-day (GMT)
    public let segments: [StackedSegment] // biggest-first (bottom-up), 0-line repos dropped
    public let total: Int                 // sum of segments

    public init(date: Date, segments: [StackedSegment]) {
        self.date = date
        self.segments = segments
        self.total = segments.reduce(0) { $0 + $1.lines }
    }
}

/// The hard cap on how many days of stacked bars we ever build: 1 YEAR. Older history is
/// kept intact in the engine; only the drawn window is bounded (matching the churn cap).
public let stackedBarMaxDaysBack = 365

/// How many of the most-recent stacked days fill the chart's DEFAULT viewport (~6 months).
/// The full series spans `stackedBarMaxDaysBack` so the strip is scrollable; it opens
/// scrolled to today showing this many days. Independent of the Totals period.
public let stackedDefaultVisibleDays = 180

/// Build a DENSE, day-filled stacked cumulative series: for EVERY calendar day from
/// `daysBack` days ago through `now`'s start-of-day, each repo contributes its
/// carry-forward cumulative `netLines` (the last point with date ≤ that day; 0 before the
/// repo's first commit, clamped ≥ 0). The per-day segments are sorted biggest-first
/// (biggest repo drawn at the bottom), 0-line repos dropped, and `total` is the day's
/// codebase size. `daysBack` is clamped to `[0, stackedBarMaxDaysBack]`. PURE: no I/O.
///
/// This is the "how many lines REALLY existed on a given day" chart — cumulative codebase
/// size stacked by repo, which grows over time — NOT per-day churn.
public func stackedRepoSeries(_ repos: [RepoStats], daysBack: Int,
                              metric: GrowthMetric = .lines, now: Date) -> [StackedDayBar] {
    let cal = GitStatsService.gmtCalendar
    let capped = min(max(daysBack, 0), stackedBarMaxDaysBack)
    let windowStart = cal.date(byAdding: .day, value: -capped, to: now) ?? .distantPast

    // Pre-sort each repo's history oldest-first once so the per-day carry-forward is a
    // single forward walk (a moving pointer) rather than an O(history) scan per day. The
    // per-point cumulative value for the chosen metric is precomputed here: `lines` is
    // already cumulative (netLines); `code`/`data` are prefix sums of the per-day classified
    // deltas (codeAdded-codeRemoved / dataAdded-dataRemoved), so lines == code + data.
    struct RepoSeries { let name: String; let dates: [Date]; let cum: [Int] }
    let prepared: [RepoSeries] = repos.map { repo in
        let pts = repo.history.sorted { $0.date < $1.date }
        var cum = [Int](); cum.reserveCapacity(pts.count)
        var running = 0
        for p in pts {
            switch metric {
            case .lines: running = p.netLines
            case .code:  running += p.codeAdded - p.codeRemoved
            case .data:  running += p.dataAdded - p.dataRemoved
            }
            cum.append(running)
        }
        return RepoSeries(name: repo.repoName, dates: pts.map(\.date), cum: cum)
    }

    var bars: [StackedDayBar] = []
    var current = cal.startOfDay(for: windowStart)
    let end = cal.startOfDay(for: now)
    guard current <= end else { return [] }

    // One advancing index per repo: the last point with date ≤ current day.
    var cursors = [Int](repeating: -1, count: prepared.count)

    while current <= end {
        var segments: [StackedSegment] = []
        for (i, series) in prepared.enumerated() {
            // Advance this repo's cursor to the last point whose date ≤ current.
            var idx = cursors[i]
            while idx + 1 < series.dates.count && series.dates[idx + 1] <= current {
                idx += 1
            }
            cursors[i] = idx
            let lines = idx >= 0 ? max(series.cum[idx], 0) : 0
            if lines > 0 {
                segments.append(StackedSegment(repoName: series.name, lines: lines))
            }
        }
        // Biggest-first (drawn bottom-up); ties broken by name for determinism.
        segments.sort { $0.lines != $1.lines ? $0.lines > $1.lines : $0.repoName < $1.repoName }
        bars.append(StackedDayBar(date: current, segments: segments))
        guard let next = cal.date(byAdding: .day, value: 1, to: current) else { break }
        current = next
    }
    return bars
}

/// The peak total (codebase size) across a stacked series (1 floored), the denominator
/// the view normalizes every bar's height against so the tallest day fills the plot.
public func stackedPeak(_ bars: [StackedDayBar]) -> Int {
    max(bars.map(\.total).max() ?? 0, 1)
}

/// The pixel height of one repo's segment against a resolved plot `height` and a shared
/// `peak` denominator (from `stackedPeak`): `lines / peak * height`, floored at 1px when
/// `lines > 0` so a tiny-but-present repo stays visible; 0 when the repo has no lines.
public func stackedSegmentHeight(lines: Int, peak: Int, height: CGFloat) -> CGFloat {
    guard lines > 0 else { return 0 }
    let denom = CGFloat(max(peak, 1))
    return max(CGFloat(lines) / denom * height, 1)
}

// MARK: - Stacked chart axes (month X-labels + nice Y-ticks)

/// One X-axis month label for the stacked strip: the short month name and the pixel
/// `x` offset of the day-column where that month begins.
public struct MonthLabel: Equatable, Sendable, Identifiable {
    public var id: CGFloat { x }
    public let label: String      // "Jun" (or "Jun '26" across a year boundary)
    public let x: CGFloat         // dayIndex · slotWidth from the strip's leading edge
    public init(label: String, x: CGFloat) {
        self.label = label
        self.x = x
    }
}

/// One label per MONTH BOUNDARY in a day-filled stacked series, positioned under the
/// bars. A boundary is the first day of each distinct (GMT year, month); index 0 always
/// emits so the leading edge is labeled. Deduped by construction (one label per month).
/// `x = dayIndex · slotWidth`. The label is "MMM"; if the series spans more than one
/// calendar year it disambiguates with "MMM ''yy" so repeated months read distinctly.
/// PURE + deterministic (POSIX locale, GMT) so snapshots and tests are stable.
public func monthLabelPositions(_ bars: [StackedDayBar], slotWidth: CGFloat) -> [MonthLabel] {
    guard !bars.isEmpty else { return [] }
    let cal = GitStatsService.gmtCalendar
    // Span >1 calendar year → include the year so "Jun '25" vs "Jun '26" don't collide.
    let years = Set(bars.map { cal.component(.year, from: $0.date) })
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "GMT")
    f.dateFormat = years.count > 1 ? "MMM ''yy" : "MMM"

    var labels: [MonthLabel] = []
    var previousKey: DateComponents? = nil
    for (i, bar) in bars.enumerated() {
        let key = cal.dateComponents([.year, .month], from: bar.date)
        if key != previousKey {
            labels.append(MonthLabel(label: f.string(from: bar.date), x: CGFloat(i) * slotWidth))
            previousKey = key
        }
    }
    return labels
}

/// 3–4 "nice" round Y-axis ticks covering `[0, peak]`: `[0, step, 2·step, …]` where
/// `step` is a 1/2/5 × 10ⁿ number and the LAST tick is the smallest multiple of `step`
/// that is ≥ `peak` (so the tallest bar fits under the top gridline). `count` is the
/// target number of intervals (default 4 → up to ~5 ticks). `peak ≤ 0` → `[0]`. Returns
/// strictly-increasing tick VALUES; the view formats them (e.g. via `formatCompactTokens`).
public func niceTicks(peak: Int, count: Int = 4) -> [Int] {
    guard peak > 0 else { return [0] }
    let intervals = max(count, 1)
    let rawStep = Double(peak) / Double(intervals)
    // Round the raw step UP to the nearest 1/2/5 × 10ⁿ "nice" number.
    let magnitude = pow(10.0, floor(log10(rawStep)))
    let normalized = rawStep / magnitude          // in [1, 10)
    let niceNormalized: Double
    if normalized <= 1 { niceNormalized = 1 }
    else if normalized <= 2 { niceNormalized = 2 }
    else if normalized <= 5 { niceNormalized = 5 }
    else { niceNormalized = 10 }
    let step = Int((niceNormalized * magnitude).rounded())
    guard step > 0 else { return [0, peak] }
    var ticks = [0]
    var value = step
    while value < peak {
        ticks.append(value)
        value += step
    }
    ticks.append(value)   // smallest multiple ≥ peak (the top gridline ≥ the tallest bar)
    return ticks
}

/// The per-day tooltip for a tapped stacked bar: a short GMT date plus that day's total
/// codebase size ("Jun 14 · 48,790 lines"). A day before any repo had code reads
/// "· no code yet". Pure + deterministic (POSIX, GMT) so it's unit-testable.
public func stackedDayReadout(_ bar: StackedDayBar) -> String {
    let date = shortDayDateText(bar.date)
    guard bar.total > 0 else { return "\(date) · no code yet" }
    let lines = groupedThousands(bar.total)
    return "\(date) · \(lines) lines"
}

/// "Jun 14" style short date for a bar's GMT start-of-day. Deterministic
/// (POSIX locale, GMT) so snapshots and tests are stable.
public func shortDayDateText(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "GMT")
    f.dateFormat = "MMM d"
    return f.string(from: date)
}

// MARK: - Per-repo color ramp (distinct, readable on dark)

/// A distinct color for the repo at `index` of `count` repos in the stacked chart's
/// legend + bars, spread across the brand `Palette.heat` ramp (blue → yellow → pink) so
/// adjacent repos are visibly different and every color stays readable on the dark cards.
/// A single repo gets `Palette.primary` (no spread). The mapping is pure and stable for a
/// given (index, count), so a repo keeps its color across days and matches its per-repo
/// block when callers feed a stable ordering (e.g. sorted-by-name, as `repoCells` does).
func repoColor(index: Int, count: Int) -> Color {
    guard count > 1 else { return Palette.primary }
    let clamped = min(max(index, 0), count - 1)
    return Palette.heat(Double(clamped) / Double(count - 1))
}

// MARK: - Per-repo display blocks

/// One per-repo block on the screen: name, default branch (read-only for now), total
/// LOC, and a NET period delta (cumulative-state difference, churn-free) with a formatted
/// ▲/▼ triangle. `net` is how much this repo's codebase grew (or shrank) over the period —
/// a line churned 5× counts once.
public struct RepoCard: Equatable, Sendable, Identifiable {
    public var id: String { repoPath }
    public let repoName: String
    public let repoPath: String           // absolute repo path; keys the branch switcher
    public let defaultBranch: String      // EFFECTIVE branch (resolved or overridden)
    public let totalLines: Int
    public let totalLinesText: String
    public let net: Int                   // net line growth/shrink over the period
    public let triangle: DeltaTriangle
    public init(repoName: String, repoPath: String, defaultBranch: String, totalLines: Int,
                net: Int) {
        self.repoName = repoName
        self.repoPath = repoPath
        self.defaultBranch = defaultBranch
        self.totalLines = totalLines
        self.totalLinesText = groupedThousands(totalLines)
        self.net = net
        self.triangle = deltaTriangle(net: net)
    }
}

/// Build the per-repo blocks, sorted by repo name. Each block's NET delta is recomputed
/// for `period` from that repo's cumulative `netLines` history (no re-scan, churn-free
/// state difference), so switching the period updates every repo in lockstep with the
/// Totals card.
public func repoCells(_ repos: [RepoStats], period: StatsPeriod, now: Date) -> [RepoCard] {
    repos.map { repo in
        let net = netLinesDelta(repo: repo.history, period: period, now: now)
        return RepoCard(repoName: repo.repoName, repoPath: repo.repoPath,
                        defaultBranch: repo.defaultBranch,
                        totalLines: repo.stats.totalLines, net: net)
    }
    .sorted { $0.repoName < $1.repoName }
}

// MARK: - Memo caches for expensive in-body aggregations

/// Memoizes `stackedRepoSeries` (the 365-day × N-repo cumulative chart). Reference type so
/// writing it inside a SwiftUI `body` does NOT itself trigger a re-render. Keyed on
/// `(projectID, scope, scannedAt, metric)` — the only four inputs that should change the
/// series. `now` is threaded as a stable anchor captured once per scan (not `Date.now` per
/// render tick), so the key is stable across hover ticks.
final class SeriesCache {
    private var projectID: UUID?
    private var scope: Set<String> = []
    private var scannedAt: Date?
    private var metric: GrowthMetric?
    private var value: [StackedDayBar]?

    /// Return the cached series if all key fields match; otherwise call `compute`, store, and
    /// return the result. `compute` receives the repos + anchor `now` and should call
    /// `stackedRepoSeries` (injected so tests can count invocations without a full scan).
    func bars(projectID: UUID, scope: Set<String>, scannedAt: Date,
              metric: GrowthMetric, now: Date, repos: [RepoStats],
              compute: ([RepoStats], Date) -> [StackedDayBar]) -> [StackedDayBar] {
        if self.projectID == projectID, self.scope == scope,
           self.scannedAt == scannedAt, self.metric == metric,
           let cached = value {
            return cached
        }
        let result = compute(repos, now)
        self.projectID = projectID
        self.scope = scope
        self.scannedAt = scannedAt
        self.metric = metric
        self.value = result
        return result
    }
}

/// Memoizes `repoCells` (the per-repo card list). Reference type for the same reason as
/// `SeriesCache`. Keyed on `(projectID, scope, scannedAt, period)` — period changes drive
/// a delta recompute, scannedAt/scope changes reflect a new scan or changed repo selection.
final class RepoCellsCache {
    private var projectID: UUID?
    private var scope: Set<String> = []
    private var scannedAt: Date?
    private var period: StatsPeriod?
    private var value: [RepoCard]?

    /// Return the cached cells if all key fields match; otherwise call `compute`, store, and
    /// return the result. `compute` receives repos + anchor `now`.
    func cells(projectID: UUID, scope: Set<String>, scannedAt: Date,
               period: StatsPeriod, now: Date, repos: [RepoStats],
               compute: ([RepoStats], Date) -> [RepoCard]) -> [RepoCard] {
        if self.projectID == projectID, self.scope == scope,
           self.scannedAt == scannedAt, self.period == period,
           let cached = value {
            return cached
        }
        let result = compute(repos, now)
        self.projectID = projectID
        self.scope = scope
        self.scannedAt = scannedAt
        self.period = period
        self.value = result
        return result
    }
}
