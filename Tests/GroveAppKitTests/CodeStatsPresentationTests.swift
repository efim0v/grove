import XCTest
@testable import GroveAppKit
import GroveCore

final class CodeStatsPresentationTests: XCTestCase {

    // MARK: - Fixtures

    private func stats(_ langs: [LanguageStats],
                       files: Int? = nil, code: Int? = nil,
                       comment: Int? = nil, blank: Int? = nil) -> CodeStats {
        let c = code ?? langs.map(\.code).reduce(0, +)
        let cm = comment ?? langs.map(\.comment).reduce(0, +)
        let bl = blank ?? langs.map(\.blank).reduce(0, +)
        let f = files ?? langs.map(\.files).reduce(0, +)
        return CodeStats(totalFiles: f, totalLines: c + cm + bl, code: c, comment: cm, blank: bl,
                         byLanguage: langs, scannedAt: Date(timeIntervalSince1970: 1_000_000),
                         skippedBinary: 0)
    }

    private func lang(_ name: String, files: Int, code: Int, comment: Int = 0, blank: Int = 0) -> LanguageStats {
        LanguageStats(language: name, files: files, code: code, comment: comment, blank: blank,
                      total: code + comment + blank)
    }

    // MARK: - languageBars

    func testLanguageBarsFractionRelativeToBusiestLanguage() {
        let s = stats([
            lang("Swift", files: 10, code: 1000, comment: 100, blank: 50),
            lang("Python", files: 5, code: 250, comment: 20, blank: 10),
        ])
        let bars = languageBars(s)
        XCTAssertEqual(bars.map(\.language), ["Swift", "Python"])   // order preserved
        XCTAssertEqual(bars[0].fraction, 1.0)                       // busiest -> 1.0
        XCTAssertEqual(bars[1].fraction, 0.25, accuracy: 1e-9)      // 250 / 1000
        XCTAssertEqual(bars[0].id, "Swift")
        XCTAssertEqual(bars[0].codeText, "1k")
        XCTAssertEqual(bars[0].commentText, "100")
        XCTAssertEqual(bars[1].codeText, "250")
        XCTAssertEqual(bars[1].filesText, "5")
    }

    func testLanguageBarsEmptyStatsYieldsNoBars() {
        XCTAssertTrue(languageBars(stats([])).isEmpty)
    }

    func testLanguageBarsZeroMaxCodeAvoidsDivideByZero() {
        // A language present but with zero code (all comment) -> fraction 0, no NaN.
        let bars = languageBars(stats([lang("Markdown", files: 1, code: 0, comment: 5)]))
        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars[0].fraction, 0)
    }

    // MARK: - statsTotals

    func testStatsTotalsFormattedHeadline() {
        // 12,481 lines total: 8861 code -> 71% (8861/12481 = 0.7099...).
        let s = stats([lang("Swift", files: 384, code: 8861)],
                      files: 384, code: 8861, comment: 2620, blank: 1000)
        let totals = statsTotals(s)
        XCTAssertEqual(totals.totalLines, 12_481)
        XCTAssertEqual(totals.totalFiles, 384)
        XCTAssertEqual(totals.codePercent, 71)
        XCTAssertEqual(totals.formatted, "12,481 lines · 384 files · 71% code")
    }

    func testStatsTotalsEmptyIsZeroPercent() {
        let totals = statsTotals(stats([]))
        XCTAssertEqual(totals.codePercent, 0)
        XCTAssertEqual(totals.formatted, "0 lines · 0 files · 0% code")
    }

    // MARK: - growthSeries

    func testGrowthSeriesShortHistoryKeptVerbatim() {
        let history = (0..<5).map { i in
            CodeStatsPoint(date: Date(timeIntervalSince1970: Double(i) * 3600),
                           totalLines: i * 100, code: i * 80, comment: i * 15, blank: i * 5,
                           totalFiles: i)
        }
        let series = growthSeries(history)
        XCTAssertEqual(series.count, 5)
        XCTAssertEqual(series.map(\.totalLines), [0, 100, 200, 300, 400])
        XCTAssertEqual(series.first?.date, history.first?.date)
        XCTAssertEqual(series.first?.id, history.first?.date)
    }

    func testGrowthSeriesLongHistoryDownsampledKeepingEndpoints() {
        let count = 1000
        let history = (0..<count).map { i in
            CodeStatsPoint(date: Date(timeIntervalSince1970: Double(i)),
                           totalLines: i, code: i, comment: 0, blank: 0, totalFiles: 0)
        }
        let series = growthSeries(history)
        XCTAssertLessThanOrEqual(series.count, 200)
        XCTAssertGreaterThan(series.count, 1)
        // First and last points are exact (endpoints preserved).
        XCTAssertEqual(series.first?.totalLines, 0)
        XCTAssertEqual(series.last?.totalLines, count - 1)
        // Strictly increasing dates (no duplicate points after downsample).
        XCTAssertEqual(series.map(\.date), series.map(\.date).sorted())
        XCTAssertEqual(Set(series.map(\.date)).count, series.count)
    }

    func testGrowthSeriesEmpty() {
        XCTAssertTrue(growthSeries([]).isEmpty)
    }

    // MARK: - buildStatsTree

    /// Tree:
    ///   Sources/  (Sources, Sources/App)
    ///   Tests/
    ///   vendor/   (excluded directly; child vendor/lib inherits)
    private func sampleTree() -> DirNode {
        DirNode(name: "project", relativePath: "", children: [
            DirNode(name: "Sources", relativePath: "Sources", children: [
                DirNode(name: "App", relativePath: "Sources/App", children: []),
            ]),
            DirNode(name: "Tests", relativePath: "Tests", children: []),
            DirNode(name: "vendor", relativePath: "vendor", children: [
                DirNode(name: "lib", relativePath: "vendor/lib", children: []),
            ]),
        ])
    }

    func testBuildStatsTreeFlattensWithDepthAndOrder() {
        let rows = buildStatsTree(sampleTree(), ignoredFolders: [])
        // Root is NOT emitted; children depth-first in DirNode order.
        XCTAssertEqual(rows.map(\.relativePath),
                       ["Sources", "Sources/App", "Tests", "vendor", "vendor/lib"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0, 0, 1])
        XCTAssertEqual(rows.map(\.name), ["Sources", "App", "Tests", "vendor", "lib"])
        XCTAssertEqual(rows[0].id, "Sources")
        XCTAssertTrue(rows.allSatisfy { !$0.isExcluded })
    }

    func testBuildStatsTreeMarksExcludedAndInheritsToDescendants() {
        let rows = buildStatsTree(sampleTree(), ignoredFolders: ["vendor"])
        let byPath = Dictionary(uniqueKeysWithValues: rows.map { ($0.relativePath, $0) })

        // vendor is directly excluded.
        XCTAssertTrue(byPath["vendor"]!.isExcluded)
        XCTAssertFalse(byPath["vendor"]!.excludedByAncestor)
        // vendor/lib inherits exclusion from its ancestor.
        XCTAssertTrue(byPath["vendor/lib"]!.isExcluded)
        XCTAssertTrue(byPath["vendor/lib"]!.excludedByAncestor)
        // Unrelated folders stay included.
        XCTAssertFalse(byPath["Sources"]!.isExcluded)
        XCTAssertFalse(byPath["Sources/App"]!.isExcluded)
        XCTAssertFalse(byPath["Tests"]!.isExcluded)
    }

    func testBuildStatsTreeNestedExclusionMarksOnlySubtree() {
        let rows = buildStatsTree(sampleTree(), ignoredFolders: ["Sources/App"])
        let byPath = Dictionary(uniqueKeysWithValues: rows.map { ($0.relativePath, $0) })
        XCTAssertFalse(byPath["Sources"]!.isExcluded)        // parent not excluded
        XCTAssertTrue(byPath["Sources/App"]!.isExcluded)     // the marked folder
        XCTAssertFalse(byPath["Sources/App"]!.excludedByAncestor)
    }

    func testBuildStatsTreeEmptyRoot() {
        let rows = buildStatsTree(DirNode(name: "p", relativePath: "", children: []),
                                  ignoredFolders: [])
        XCTAssertTrue(rows.isEmpty)
    }
}
