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

// MARK: - Per-day bar model (growth chart)

/// One bar: a day's carry-forward cumulative total plus that day's added/removed (so
/// selecting two bars can show the window delta without a separate lookup).
public struct BarPoint: Equatable, Sendable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let cumulativeLines: Int   // = CodeStatsPoint.totalLines (carry-forward total)
    public let dayAdded: Int
    public let dayRemoved: Int
    public init(date: Date, cumulativeLines: Int, dayAdded: Int, dayRemoved: Int) {
        self.date = date
        self.cumulativeLines = cumulativeLines
        self.dayAdded = dayAdded
        self.dayRemoved = dayRemoved
    }
}

/// Build the per-day bar series from an aggregate history (oldest-first). Long
/// histories are evenly downsampled to ≤ `barMaxPoints`, always keeping the FIRST and
/// LAST day so the endpoints stay exact.
public func barSeries(_ history: [CodeStatsPoint]) -> [BarPoint] {
    let points = history.map {
        BarPoint(date: $0.date, cumulativeLines: $0.totalLines,
                 dayAdded: $0.dayAdded, dayRemoved: $0.dayRemoved)
    }
    guard points.count > barMaxPoints else { return points }
    let stride = Double(points.count - 1) / Double(barMaxPoints - 1)
    var picked: [BarPoint] = []
    var lastIndex = -1
    for i in 0..<barMaxPoints {
        let index = Int((Double(i) * stride).rounded())
        if index != lastIndex { picked.append(points[index]); lastIndex = index }
    }
    if let last = points.last, picked.last?.date != last.date { picked.append(last) }
    return picked
}

/// The largest bar count we'll render before downsampling.
private let barMaxPoints = 200

// MARK: - Two-bar selection delta

/// The delta between two selected bars. `added`/`removed` SUM each day's value over the
/// half-open window (earlier, later] — the honest per-day churn within the selection.
/// `net` is the AUTHORITATIVE cumulative difference (`later.cumulativeLines −
/// earlier.cumulativeLines`), carried separately rather than derived from
/// `added − removed`: after downsampling, intermediate days are dropped from `bars`,
/// so the per-day sum can diverge from the true endpoint diff. Keeping `net` explicit
/// means the readout's "net" is always exact, while `added`/`removed` honestly report
/// the (possibly incomplete) per-day churn the bars retained.
public struct BarSelectionDelta: Equatable, Sendable {
    public let added: Int
    public let removed: Int
    public let net: Int
    public init(added: Int, removed: Int, net: Int) {
        self.added = added
        self.removed = removed
        self.net = net
    }
}

/// Compute the delta between two selected bars. `bars` should be the full series the two
/// points came from (used to sum the per-day churn inside the window).
public func barSelectionDelta(from a: BarPoint, to b: BarPoint, in bars: [BarPoint]) -> BarSelectionDelta {
    let earlier = a.date <= b.date ? a : b
    let later = a.date <= b.date ? b : a
    var added = 0, removed = 0
    for bar in bars where bar.date > earlier.date && bar.date <= later.date {
        added += bar.dayAdded; removed += bar.dayRemoved
    }
    // net uses the cumulative endpoints so it's exact even after downsampling, where the
    // per-day (added − removed) sum may diverge from the true endpoint diff.
    let net = later.cumulativeLines - earlier.cumulativeLines
    return BarSelectionDelta(added: added, removed: removed, net: net)
}

/// Readout for a two-bar selection: "+X added · −Y removed · net Z" (U+2212 in the
/// removed token; net carries an explicit sign). `net` is the authoritative cumulative
/// diff, NOT `added − removed`, so it stays exact even on downsampled series.
public func barSelectionReadout(_ d: BarSelectionDelta) -> String {
    let net = d.net
    let netText = net >= 0 ? "+\(groupedThousands(net))" : "\u{2212}\(groupedThousands(abs(net)))"
    return "+\(groupedThousands(d.added)) added · \u{2212}\(groupedThousands(d.removed)) removed · net \(netText)"
}

// MARK: - Per-repo display blocks

/// One per-repo block on the screen: name, default branch (read-only for now), total
/// LOC, and a period delta with a formatted ▲/▼ triangle.
public struct RepoCard: Equatable, Sendable, Identifiable {
    public var id: String { repoName }
    public let repoName: String
    public let defaultBranch: String
    public let totalLines: Int
    public let totalLinesText: String
    public let delta: RepoDelta
    public let triangle: DeltaTriangle
    public init(repoName: String, defaultBranch: String, totalLines: Int,
                delta: RepoDelta) {
        self.repoName = repoName
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
        return RepoCard(repoName: repo.repoName, defaultBranch: repo.defaultBranch,
                        totalLines: repo.stats.totalLines, delta: delta)
    }
    .sorted { $0.repoName < $1.repoName }
}
