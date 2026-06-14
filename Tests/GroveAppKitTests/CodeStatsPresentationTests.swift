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

    // MARK: - buildFileTree (per-file directory+file tree)

    private func entry(_ path: String, lines: Int, language: String = "Swift",
                       isDataProse: Bool = false) -> StatFileEntry {
        StatFileEntry(path: path, lines: lines, language: language, isDataProse: isDataProse)
    }

    func testBuildFileTreeGroupsFilesByFolder() {
        let files = [
            entry("src/a.swift", lines: 10),
            entry("src/b.swift", lines: 20),
            entry("gen/c.swift", lines: 30),
        ]
        let rows = buildFileTree(files: files, ignoredFolders: [])
        let folders = rows.filter(\.isFolder)
        XCTAssertEqual(Set(folders.map(\.relativePath)), ["src", "gen"])
        // Each file appears once, nested under its folder.
        let fileRows = rows.filter { !$0.isFolder }
        XCTAssertEqual(Set(fileRows.map(\.relativePath)), ["src/a.swift", "src/b.swift", "gen/c.swift"])
        // Folder rows precede their files (depth-first), folders sorted by name (gen < src).
        XCTAssertEqual(rows.first?.relativePath, "gen")
    }

    func testBuildFileTreeOrdersFoldersBeforeFilesMatchingNodes() {
        // A level that mixes a sibling file with subfolders: the flat (snapshot) tree
        // must emit the SUBFOLDERS before the file, identical to buildFileTreeNodes and
        // the spec ("folders first then files"). Regression guard for the snapshot path.
        let files = [
            entry("README.md", lines: 5, language: "Markdown", isDataProse: true),
            entry("Sources/a.swift", lines: 10),
            entry("Snapshot/b.swift", lines: 20),
        ]
        let rows = buildFileTree(files: files, ignoredFolders: [])
        // Top-level order: folders (Snapshot, Sources sorted) then the README file.
        let topLevel = rows.filter { $0.depth == 0 }.map(\.relativePath)
        XCTAssertEqual(topLevel, ["Snapshot", "Sources", "README.md"])
        // The flat order must match the depth-first flattening of the nested nodes.
        let nodes = buildFileTreeNodes(files: files, ignoredFolders: [])
        XCTAssertEqual(rows.map(\.relativePath), Self.flattenNodePaths(nodes))
    }

    /// Depth-first flatten of nested nodes to project-relative paths (folders emitted
    /// before their children), mirroring `buildFileTree`'s row order.
    private static func flattenNodePaths(_ nodes: [FileTreeNode]) -> [String] {
        var out: [String] = []
        func walk(_ ns: [FileTreeNode]) {
            for n in ns {
                out.append(n.relativePath)
                if let kids = n.children { walk(kids) }
            }
        }
        walk(nodes)
        return out
    }

    func testBuildFileTreeFolderLOCSummedOverDescendants() {
        let files = [
            entry("src/a.swift", lines: 10),
            entry("src/b.swift", lines: 20),
            entry("src/deep/c.swift", lines: 5),
        ]
        let rows = buildFileTree(files: files, ignoredFolders: [])
        let src = try! XCTUnwrap(rows.first { $0.relativePath == "src" && $0.isFolder })
        XCTAssertEqual(src.lines, 35, "src sums a + b + deep/c")
        XCTAssertEqual(src.fileCount, 3)
        let deep = try! XCTUnwrap(rows.first { $0.relativePath == "src/deep" && $0.isFolder })
        XCTAssertEqual(deep.lines, 5)
        XCTAssertEqual(deep.fileCount, 1)
    }

    func testBuildFileTreeRootLevelFileHasDepthZeroNoFolder() {
        let rows = buildFileTree(files: [entry("README.md", lines: 48, language: "Markdown",
                                               isDataProse: true)], ignoredFolders: [])
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].isFolder)
        XCTAssertEqual(rows[0].depth, 0)
        XCTAssertEqual(rows[0].relativePath, "README.md")
        XCTAssertEqual(rows[0].language, "Markdown")
        XCTAssertTrue(rows[0].isDataProse)
    }

    func testBuildFileTreeFolderExclusionMarksDescendants() {
        let files = [
            entry("src/a.swift", lines: 10),
            entry("src/sub/b.swift", lines: 20),
            entry("other/c.swift", lines: 5),
        ]
        let rows = buildFileTree(files: files, ignoredFolders: ["src"])
        let byPath = Dictionary(uniqueKeysWithValues: rows.map { ($0.relativePath, $0) })
        XCTAssertTrue(byPath["src"]!.isExcluded)
        XCTAssertFalse(byPath["src"]!.excludedByAncestor, "src is directly excluded")
        // Descendant file + subfolder inherit the exclusion.
        XCTAssertTrue(byPath["src/a.swift"]!.isExcluded)
        XCTAssertTrue(byPath["src/a.swift"]!.excludedByAncestor)
        XCTAssertTrue(byPath["src/sub"]!.isExcluded)
        XCTAssertTrue(byPath["src/sub"]!.excludedByAncestor)
        XCTAssertTrue(byPath["src/sub/b.swift"]!.isExcluded)
        // Unrelated folder stays included.
        XCTAssertFalse(byPath["other"]!.isExcluded)
        XCTAssertFalse(byPath["other/c.swift"]!.isExcluded)
    }

    func testBuildFileTreeMatchesInputTotals() {
        let files = [
            entry("a.swift", lines: 10),
            entry("dir/b.swift", lines: 20),
            entry("dir/sub/c.swift", lines: 30),
        ]
        let rows = buildFileTree(files: files, ignoredFolders: [])
        // Sum of FILE rows equals the input total (folders are summaries, not double-counted).
        let fileSum = rows.filter { !$0.isFolder }.reduce(0) { $0 + $1.lines }
        XCTAssertEqual(fileSum, 60)
        XCTAssertEqual(rows.filter { !$0.isFolder }.count, files.count)
    }

    func testBuildFileTreeEmptyInput() {
        XCTAssertTrue(buildFileTree(files: [], ignoredFolders: []).isEmpty)
    }

    // MARK: - buildFileTreeNodes (nested form for OutlineGroup)

    func testBuildFileTreeNodesNestStructureFoldersFirst() {
        let files = [
            entry("src/a.swift", lines: 10),
            entry("src/sub/b.swift", lines: 20),
            entry("readme.md", lines: 3, language: "Markdown", isDataProse: true),
        ]
        let nodes = buildFileTreeNodes(files: files, ignoredFolders: [])
        // Top level: folder "src" first, then file "readme.md" (folders before files).
        XCTAssertEqual(nodes.map(\.relativePath), ["src", "readme.md"])
        let src = try! XCTUnwrap(nodes.first { $0.relativePath == "src" })
        XCTAssertTrue(src.isFolder)
        XCTAssertEqual(src.lines, 30)
        // src's children: subfolder "src/sub" before file "src/a.swift".
        let children = try! XCTUnwrap(src.children)
        XCTAssertEqual(children.map(\.relativePath), ["src/sub", "src/a.swift"])
        // Files are leaves (children == nil).
        let readme = try! XCTUnwrap(nodes.first { $0.relativePath == "readme.md" })
        XCTAssertNil(readme.children)
        XCTAssertTrue(readme.isDataProse)
    }

    func testBuildFileTreeNodesExclusionPropagates() {
        let files = [entry("src/a.swift", lines: 10), entry("src/sub/b.swift", lines: 20)]
        let nodes = buildFileTreeNodes(files: files, ignoredFolders: ["src"])
        let src = try! XCTUnwrap(nodes.first { $0.relativePath == "src" })
        XCTAssertTrue(src.isExcluded)
        XCTAssertFalse(src.excludedByAncestor)
        func allDescendantsExcluded(_ node: FileTreeNode) -> Bool {
            (node.children ?? []).allSatisfy { $0.isExcluded && allDescendantsExcluded($0) }
        }
        XCTAssertTrue(allDescendantsExcluded(src), "every descendant inherits the exclusion")
    }

    // MARK: - dataProseBreakdown (Code vs Data/Prose split)

    func testDataProseBreakdownClassifiesLanguages() {
        let s = stats([
            lang("Swift", files: 10, code: 1000, comment: 100, blank: 50),   // code
            lang("Dart", files: 8, code: 800, comment: 40, blank: 20),       // code
            lang("Markdown", files: 5, code: 300, comment: 0, blank: 30),    // data/prose
            lang("JSON", files: 3, code: 200, comment: 0, blank: 0),         // data/prose
            lang("YAML", files: 2, code: 50, comment: 0, blank: 5),          // data/prose
        ])
        let bd = dataProseBreakdown(s)
        // Code lines = Swift.total (1150) + Dart.total (860) = 2010; files 18.
        XCTAssertEqual(bd.codeLines, 1150 + 860)
        XCTAssertEqual(bd.codeFiles, 18)
        // Data/Prose = Markdown.total (330) + JSON.total (200) + YAML.total (55) = 585; files 10.
        XCTAssertEqual(bd.dataProseLines, 330 + 200 + 55)
        XCTAssertEqual(bd.dataProseFiles, 10)
    }

    func testDataProseTotalsFormatsGroupedThousands() {
        let s = stats([
            lang("Swift", files: 1, code: 281_989),
            lang("Markdown", files: 1, code: 12_345),
        ])
        let bd = dataProseBreakdown(s)
        XCTAssertEqual(bd.codeLinesText, "281,989")
        XCTAssertEqual(bd.dataProseLinesText, "12,345")
        XCTAssertEqual(bd.codeFilesText, "1")
    }

    func testDataProseBreakdownEmptyIsZero() {
        let bd = dataProseBreakdown(stats([]))
        XCTAssertEqual(bd.codeLines, 0)
        XCTAssertEqual(bd.dataProseLines, 0)
        XCTAssertEqual(bd.codeLinesText, "0")
    }

    // MARK: - Per-day deltas + period windows

    private func historyPoints() -> [CodeStatsPoint] {
        // 4 consecutive days. Per-day added=(i+1)*10, removed=i; cumulative is the
        // running sum of (added-removed) starting at 100 so the fixture is internally
        // consistent (cumulative diff == per-day net sum). Net steps: 10,19,28,37.
        let day0 = Date(timeIntervalSince1970: 1_700_000_000)
        var cum = 100
        var points: [CodeStatsPoint] = []
        for i in 0..<4 {
            let added = (i + 1) * 10
            let removed = i
            cum += added - removed
            points.append(CodeStatsPoint(date: day0.addingTimeInterval(Double(i) * 86_400),
                                         totalLines: cum, code: cum, comment: 0, blank: 0,
                                         totalFiles: 0, dayAdded: added, dayRemoved: removed))
        }
        return points
    }

    func testAggregateDayDeltasFromHistory() {
        let dd = aggregateDayDeltas(historyPoints())
        XCTAssertEqual(dd.map(\.dayAdded), [10, 20, 30, 40])
        XCTAssertEqual(dd.map(\.dayRemoved), [0, 1, 2, 3])
        XCTAssertEqual(dd[1].dayNet, 19)
        XCTAssertEqual(dd[0].id, dd[0].date)
    }

    func testDeltaBetweenDatesIgnoresOutOfWindow() {
        let dd = aggregateDayDeltas(historyPoints())
        // Window [day1, day2] inclusive: added 20+30=50, removed 1+2=3.
        let start = dd[1].date
        let end = dd[2].date
        let delta = deltaBetween(start: start, end: end, dayDeltas: dd)
        XCTAssertEqual(delta.added, 50)
        XCTAssertEqual(delta.removed, 3)
        XCTAssertEqual(delta.net, 47)
        XCTAssertEqual(delta.filesChanged, 0, "not derivable client-side")
    }

    func testPeriodDeltaWindows() {
        let history = historyPoints()
        let now = history.last!.date   // day3
        // 7d window covers all 4 days (they span 3 days): added 100, removed 6.
        let all7 = periodDelta(history, period: .d7, now: now)
        XCTAssertEqual(all7.added, 10 + 20 + 30 + 40)
        XCTAssertEqual(all7.removed, 0 + 1 + 2 + 3)
        // "All" also covers everything.
        let all = periodDelta(history, period: .all, now: now)
        XCTAssertEqual(all.added, 100)
    }

    func testStatsPeriodStartAndDays() {
        XCTAssertEqual(StatsPeriod.allCases.map(\.rawValue), ["7d", "30d", "90d", "All"])
        XCTAssertEqual(StatsPeriod.d30.days, 30)
        XCTAssertNil(StatsPeriod.all.days)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(StatsPeriod.d7.start(now: now),
                       now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(StatsPeriod.all.start(now: now), .distantPast)
    }

    // MARK: - Delta triangles

    func testDeltaTriangleUpDownFlat() {
        let up = deltaTriangle(net: 1240)
        XCTAssertEqual(up.direction, .up)
        XCTAssertEqual(up.label, "▲ +1,240")
        let down = deltaTriangle(net: -50)
        XCTAssertEqual(down.direction, .down)
        XCTAssertEqual(down.label, "▼ \u{2212}50", "uses U+2212 MINUS + abs value")
        let flat = deltaTriangle(net: 0)
        XCTAssertEqual(flat.direction, .flat)
        XCTAssertEqual(flat.label, "±0")
    }

    // MARK: - CategoryDelta (honest ▲added / ▼removed) + periodDeltasByCategory

    func testCategoryDeltaFormatting() {
        let both = CategoryDelta(added: 1240, removed: 120)
        XCTAssertEqual(both.added, 1240)
        XCTAssertEqual(both.removed, 120)
        XCTAssertEqual(both.addedText, "▲ +1,240")
        XCTAssertEqual(both.removedText, "▼ \u{2212}120", "removed uses U+2212 MINUS")
        // Zero on either side renders "±0" (no triangle).
        let onlyAdded = CategoryDelta(added: 500, removed: 0)
        XCTAssertEqual(onlyAdded.addedText, "▲ +500")
        XCTAssertEqual(onlyAdded.removedText, "±0")
        let onlyRemoved = CategoryDelta(added: 0, removed: 90)
        XCTAssertEqual(onlyRemoved.addedText, "±0")
        XCTAssertEqual(onlyRemoved.removedText, "▼ \u{2212}90")
        let none = CategoryDelta(added: 0, removed: 0)
        XCTAssertEqual(none.addedText, "±0")
        XCTAssertEqual(none.removedText, "±0")
    }

    func testPeriodDeltasByCategory() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func day(_ back: Int) -> Date { now.addingTimeInterval(-Double(back) * 86_400) }
        // 3 in-window days + 1 out-of-window (40d back, outside a 30d window).
        let history = [
            CodeStatsPoint(date: day(40), totalLines: 0, code: 0, comment: 0, blank: 0, totalFiles: 0,
                           dayAdded: 1000, dayRemoved: 0, codeAdded: 1000, codeRemoved: 0,
                           dataAdded: 0, dataRemoved: 0),  // OUT of the 30d window
            CodeStatsPoint(date: day(20), totalLines: 0, code: 0, comment: 0, blank: 0, totalFiles: 0,
                           dayAdded: 300, dayRemoved: 40, codeAdded: 250, codeRemoved: 30,
                           dataAdded: 50, dataRemoved: 10),
            CodeStatsPoint(date: day(10), totalLines: 0, code: 0, comment: 0, blank: 0, totalFiles: 0,
                           dayAdded: 120, dayRemoved: 200, codeAdded: 100, codeRemoved: 180,
                           dataAdded: 20, dataRemoved: 20),
            CodeStatsPoint(date: day(1), totalLines: 0, code: 0, comment: 0, blank: 0, totalFiles: 0,
                           dayAdded: 60, dayRemoved: 5, codeAdded: 40, codeRemoved: 5,
                           dataAdded: 20, dataRemoved: 0),
        ]
        let split = periodDeltasByCategory(history, period: .d30, now: now)
        // Code over the 3 in-window days: added 250+100+40=390, removed 30+180+5=215.
        XCTAssertEqual(split.code.added, 390)
        XCTAssertEqual(split.code.removed, 215)
        // Data over the same window: added 50+20+20=90, removed 10+20+0=30.
        XCTAssertEqual(split.dataProse.added, 90)
        XCTAssertEqual(split.dataProse.removed, 30)
        // The 40d-back day (codeAdded 1000) is excluded from the 30d window.
        // "All" includes it.
        let all = periodDeltasByCategory(history, period: .all, now: now)
        XCTAssertEqual(all.code.added, 1390)
    }

    // MARK: - Churn bar series (dense, day-filled, 1yr cap)

    func testChurnBarSeriesFillsAllDays() throws {
        let cal = GitStatsService.gmtCalendar
        let now = cal.date(from: DateComponents(year: 2025, month: 6, day: 30, hour: 12))!
        // A 30-day window with commits on the boundary days and one in the middle.
        func dayStart(_ d: Int) -> Date { cal.date(from: DateComponents(year: 2025, month: 6, day: d))! }
        let history = [
            CodeStatsPoint(date: dayStart(1), totalLines: 0, code: 0, comment: 0, blank: 0, totalFiles: 0,
                           dayAdded: 100, dayRemoved: 10),
            CodeStatsPoint(date: dayStart(15), totalLines: 0, code: 0, comment: 0, blank: 0, totalFiles: 0,
                           dayAdded: 50, dayRemoved: 5),
            CodeStatsPoint(date: dayStart(30), totalLines: 0, code: 0, comment: 0, blank: 0, totalFiles: 0,
                           dayAdded: 20, dayRemoved: 2),
        ]
        let bars = churnBarSeries(history, period: .d30, now: now)
        // 30d window: now − 30·86400 = May 31 12:00 → startOfDay May 31; through June 30
        // start-of-day. Inclusive of both endpoints that is 31 calendar days, all filled.
        XCTAssertEqual(bars.count, 31, "every calendar day in the window is filled (no gaps)")
        XCTAssertEqual(bars.first?.date, cal.date(from: DateComponents(year: 2025, month: 5, day: 31)))
        XCTAssertEqual(bars.last?.date, dayStart(30))
        // Dates are strictly consecutive (+1 day apart), oldest first.
        for i in 1..<bars.count {
            let gap = bars[i].date.timeIntervalSince(bars[i - 1].date)
            XCTAssertEqual(gap, 86_400, accuracy: 1, "consecutive calendar days, no gaps")
        }
        // 3 commit days carry churn; the rest are zero-churn (filled, not transparent).
        let nonZero = bars.filter { $0.totalChurn > 0 }
        XCTAssertEqual(nonZero.count, 3)
        XCTAssertEqual(bars.filter { $0.totalChurn == 0 }.count, 28)
        // The commit-day bars carry the right stacked segments.
        let d1 = try XCTUnwrap(bars.first { $0.date == dayStart(1) })
        XCTAssertEqual(d1.dayAdded, 100)
        XCTAssertEqual(d1.dayRemoved, 10)
        XCTAssertEqual(d1.totalChurn, 110)
    }

    func testChurnBarSeriesCapAt1Year() {
        let cal = GitStatsService.gmtCalendar
        let now = cal.date(from: DateComponents(year: 2025, month: 6, day: 30, hour: 12))!
        // A 2-year-spanning history; "All" should still cap the drawn window at 1 year.
        var history: [CodeStatsPoint] = []
        var d = cal.date(from: DateComponents(year: 2023, month: 1, day: 1))!
        while d <= cal.startOfDay(for: now) {
            history.append(CodeStatsPoint(date: d, totalLines: 0, code: 0, comment: 0, blank: 0,
                                          totalFiles: 0, dayAdded: 1, dayRemoved: 0))
            d = cal.date(byAdding: .day, value: 7, to: d)!  // weekly points
        }
        let bars = churnBarSeries(history, period: .all, now: now)
        XCTAssertLessThanOrEqual(bars.count, 366, "1-year (366 incl. leap) cap on drawn bars")
        // No bar older than now − 365d.
        let cutoff = cal.date(byAdding: .day, value: -churnBarMaxDaysBack, to: now)!
        XCTAssertTrue(bars.allSatisfy { $0.date >= cal.startOfDay(for: cutoff) },
                      "no drawn bar predates the 1-year cap")
        // Still day-filled within the cap (consecutive days).
        for i in 1..<bars.count {
            XCTAssertEqual(bars[i].date.timeIntervalSince(bars[i - 1].date), 86_400, accuracy: 1)
        }
    }

    func testChurnBarSeriesEmptyHistory() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Even with NO history, the window is fully filled with zero-churn bars (no gaps).
        // 7d window inclusive of both endpoints = 8 calendar days.
        let bars = churnBarSeries([], period: .d7, now: now)
        XCTAssertEqual(bars.count, 8)
        XCTAssertTrue(bars.allSatisfy { $0.totalChurn == 0 })
    }

    /// The live histogram window is DECOUPLED from the Totals delta period: it always
    /// asks for the full 1-year span (`daysBack:`), so the strip is genuinely scrollable
    /// regardless of which 7d/30d/90d/All the deltas show. A 1-year request yields the
    /// full ~366 day-filled bars; a tiny request still day-fills exactly its window.
    func testChurnBarSeriesDaysBackDecoupledFromPeriod() {
        let cal = GitStatsService.gmtCalendar
        let now = cal.date(from: DateComponents(year: 2025, month: 6, day: 30, hour: 12))!
        // Sparse history (one old commit) — the window must NOT shrink to the data.
        let history = [
            CodeStatsPoint(date: cal.date(from: DateComponents(year: 2025, month: 1, day: 10))!,
                           totalLines: 0, code: 0, comment: 0, blank: 0, totalFiles: 0,
                           dayAdded: 100, dayRemoved: 10),
        ]
        // Full 1-year span: 365 days back through today inclusive = 366 day-filled bars.
        let year = churnBarSeries(history, daysBack: churnBarMaxDaysBack, now: now)
        XCTAssertEqual(year.count, 366, "the full 1-year strip is built so it's scrollable")
        XCTAssertEqual(year.last?.date, cal.startOfDay(for: now))
        XCTAssertEqual(year.filter { $0.totalChurn > 0 }.count, 1, "only the one commit day has churn")
        // The default-viewport span is a strict subset of the full strip (scroll-back room).
        XCTAssertGreaterThan(year.count, churnDefaultVisibleDays,
                             "the 1-year strip has older days to scroll back to beyond the default viewport")
        // A request beyond the cap is clamped to 1 year (presentation-only bound).
        let capped = churnBarSeries(history, daysBack: 10_000, now: now)
        XCTAssertEqual(capped.count, 366, "daysBack is clamped to the 1-year cap")
        // A small explicit window day-fills exactly its span (7 back + today = 8).
        let week = churnBarSeries(history, daysBack: 7, now: now)
        XCTAssertEqual(week.count, 8)
    }

    // MARK: - Churn bar geometry (peak, stacked segment heights) + tooltip

    func testChurnPeakIsMaxTotalChurnFlooredAtOne() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let bars = [
            ChurnBarPoint(date: day, dayAdded: 100, dayRemoved: 20),                       // 120
            ChurnBarPoint(date: day.addingTimeInterval(86_400), dayAdded: 300, dayRemoved: 50), // 350 (peak)
            ChurnBarPoint(date: day.addingTimeInterval(172_800), dayAdded: 0, dayRemoved: 0),    // 0
        ]
        XCTAssertEqual(churnPeak(bars), 350)
        // An all-zero (or empty) series floors at 1 so the view never divides by zero.
        XCTAssertEqual(churnPeak([ChurnBarPoint(date: day, dayAdded: 0, dayRemoved: 0)]), 1)
        XCTAssertEqual(churnPeak([]), 1)
    }

    func testChurnBarHeightsStackProportionalToTotalChurn() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        // peak = 200; a day with added 100 / removed 50 (total 150) over a 120pt plot.
        let bar = ChurnBarPoint(date: day, dayAdded: 100, dayRemoved: 50)
        let h = churnBarHeights(bar, peak: 200, height: 120)
        // added = 100/200*120 = 60; removed = 50/200*120 = 30; total = 90 (= 150/200*120).
        XCTAssertEqual(h.added, 60, accuracy: 0.001)
        XCTAssertEqual(h.removed, 30, accuracy: 0.001)
        XCTAssertEqual(h.total, 90, accuracy: 0.001)
        // The peak day fills the whole plot.
        let peakBar = ChurnBarPoint(date: day, dayAdded: 150, dayRemoved: 50)  // total 200 = peak
        XCTAssertEqual(churnBarHeights(peakBar, peak: 200, height: 120).total, 120, accuracy: 0.001)
    }

    func testChurnBarHeightsZeroDayIsFlat() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let h = churnBarHeights(ChurnBarPoint(date: day, dayAdded: 0, dayRemoved: 0),
                                peak: 200, height: 120)
        XCTAssertEqual(h.added, 0)
        XCTAssertEqual(h.removed, 0)
        XCTAssertEqual(h.total, 0, "a true zero-churn day draws no stacked segment")
    }

    func testChurnBarHeightsTinyNonZeroSegmentFlooredAtOnePixel() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        // A real-but-tiny day (1 added against a 1,000,000 peak) still shows a ≥1px sliver
        // per non-zero segment so it isn't invisible; the (zero) removed segment stays 0.
        let h = churnBarHeights(ChurnBarPoint(date: day, dayAdded: 1, dayRemoved: 0),
                                peak: 1_000_000, height: 120)
        XCTAssertEqual(h.added, 1, "non-zero added floors at 1px")
        XCTAssertEqual(h.removed, 0, "zero removed stays flat (no spurious sliver)")
    }

    func testChurnDayReadoutFormatsBothSides() {
        let cal = GitStatsService.gmtCalendar
        let day = cal.date(from: DateComponents(year: 2026, month: 6, day: 14))!
        let bar = ChurnBarPoint(date: day, dayAdded: 1_240, dayRemoved: 120)
        XCTAssertEqual(churnDayReadout(bar), "Jun 14 · +1,240 \u{2212}120",
                       "short GMT date + honest +added / −removed (U+2212 minus)")
        // A zero-churn day reads "no commits".
        let empty = ChurnBarPoint(date: day, dayAdded: 0, dayRemoved: 0)
        XCTAssertEqual(churnDayReadout(empty), "Jun 14 · no commits")
        XCTAssertEqual(churnDayDateText(day), "Jun 14")
    }

    // MARK: - Per-repo cards

    private func repoStat(_ name: String, branch: String, totalLines: Int,
                          history: [RepoHistoryPoint]) -> RepoStats {
        let cs = CodeStats(totalFiles: 1, totalLines: totalLines, code: totalLines,
                           comment: 0, blank: 0,
                           byLanguage: [LanguageStats(language: "Swift", files: 1,
                                                      code: totalLines, comment: 0, blank: 0,
                                                      total: totalLines)],
                           scannedAt: Date(timeIntervalSince1970: 0), skippedBinary: 0)
        return RepoStats(repoPath: "/tmp/\(name)", repoName: name, defaultBranch: branch,
                         stats: cs, history: history, delta: .zero)
    }

    func testRepoCardsFormatDelta() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day = now.addingTimeInterval(-2 * 86_400)
        let repo = repoStat("app", branch: "main", totalLines: 12_481,
                            history: [RepoHistoryPoint(date: day, netLines: 240,
                                                       dayAdded: 300, dayRemoved: 60)])
        let cards = repoCells([repo], period: .d7, now: now)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].repoName, "app")
        XCTAssertEqual(cards[0].defaultBranch, "main")
        XCTAssertEqual(cards[0].totalLinesText, "12,481")
        // Period delta from per-day history: net = 300 - 60 = 240.
        XCTAssertEqual(cards[0].delta.net, 240)
        XCTAssertEqual(cards[0].triangle.direction, .up)
        XCTAssertEqual(cards[0].triangle.label, "▲ +240")
    }

    func testRepoCellsSortByName() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let z = repoStat("zebra", branch: "main", totalLines: 1, history: [])
        let a = repoStat("alpha", branch: "dev", totalLines: 2, history: [])
        let m = repoStat("mid", branch: "main", totalLines: 3, history: [])
        let cards = repoCells([z, a, m], period: .d30, now: now)
        XCTAssertEqual(cards.map(\.repoName), ["alpha", "mid", "zebra"])
    }

    func testRepoCardCarriesRepoPath() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let repo = repoStat("app", branch: "main", totalLines: 100, history: [])
        let cards = repoCells([repo], period: .d7, now: now)
        XCTAssertEqual(cards.count, 1)
        // repoPath is threaded through so the row can key the branch switcher off it.
        XCTAssertEqual(cards[0].repoPath, "/tmp/app")
        XCTAssertEqual(cards[0].repoName, "app")
        XCTAssertEqual(cards[0].id, "/tmp/app", "RepoCard.id is the repoPath")
    }

    func testRepoCellsPeriodFiltersOutOfWindowDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = now.addingTimeInterval(-3 * 86_400)   // in 7d window
        let old = now.addingTimeInterval(-40 * 86_400)     // out of 7d window
        let repo = repoStat("app", branch: "main", totalLines: 100, history: [
            RepoHistoryPoint(date: old, netLines: 500, dayAdded: 500, dayRemoved: 0),
            RepoHistoryPoint(date: recent, netLines: 510, dayAdded: 10, dayRemoved: 0),
        ])
        let cards = repoCells([repo], period: .d7, now: now)
        XCTAssertEqual(cards[0].delta.added, 10, "old day excluded from 7d window")
    }
}
