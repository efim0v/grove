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

// MARK: - Growth series (lines over time)

/// One point on the "lines over time" chart. `id` is `date` so ForEach is stable.
public struct GrowthPoint: Equatable, Sendable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let totalLines: Int

    public init(date: Date, totalLines: Int) {
        self.date = date
        self.totalLines = totalLines
    }
}

/// The smallest history we'll downsample (below this every point is kept as-is).
private let growthMaxPoints = 200

/// Build the growth series from a project's history (oldest first). Long histories
/// are evenly downsampled to at most `growthMaxPoints` points — the FIRST and LAST
/// points are always kept so the curve's endpoints stay exact.
public func growthSeries(_ history: [CodeStatsPoint]) -> [GrowthPoint] {
    let points = history.map { GrowthPoint(date: $0.date, totalLines: $0.totalLines) }
    guard points.count > growthMaxPoints else { return points }
    // Even stride keeps the shape; force-include the last index so the tail is exact.
    let stride = Double(points.count - 1) / Double(growthMaxPoints - 1)
    var picked: [GrowthPoint] = []
    var lastIndex = -1
    for i in 0..<growthMaxPoints {
        let index = Int((Double(i) * stride).rounded())
        if index != lastIndex { picked.append(points[index]); lastIndex = index }
    }
    if let last = points.last, picked.last?.date != last.date { picked.append(last) }
    return picked
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
