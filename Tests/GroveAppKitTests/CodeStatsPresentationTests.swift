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

    // MARK: - Bar series + two-bar selection

    func testBarSeriesFromHistoryKeepsFirstAndLast() {
        let bars = barSeries(historyPoints())
        XCTAssertEqual(bars.count, 4)
        XCTAssertEqual(bars.map(\.cumulativeLines), [110, 129, 157, 194])
        XCTAssertEqual(bars.first?.dayAdded, 10)
        XCTAssertEqual(bars.last?.dayRemoved, 3)
        XCTAssertEqual(bars.first?.id, bars.first?.date)
    }

    func testBarSeriesLongDownsampledKeepingEndpoints() {
        let count = 1000
        let day0 = Date(timeIntervalSince1970: 1_700_000_000)
        let history = (0..<count).map { i in
            CodeStatsPoint(date: day0.addingTimeInterval(Double(i) * 86_400),
                           totalLines: i, code: i, comment: 0, blank: 0, totalFiles: 0,
                           dayAdded: 1, dayRemoved: 0)
        }
        let bars = barSeries(history)
        XCTAssertLessThanOrEqual(bars.count, 200)
        XCTAssertEqual(bars.first?.cumulativeLines, 0)
        XCTAssertEqual(bars.last?.cumulativeLines, count - 1)
    }

    func testBarSelectionDeltaNetMatchesCumulativeDiff() {
        let bars = barSeries(historyPoints())
        // Select day0 (cum 110) and day3 (cum 194): net = 84.
        let d = barSelectionDelta(from: bars[0], to: bars[3], in: bars)
        XCTAssertEqual(d.net, 84, "later.cumulative - earlier.cumulative")
        // added sums (earlier, later]: days 1,2,3 -> 20+30+40 = 90; removed 1+2+3 = 6.
        XCTAssertEqual(d.added, 90)
        XCTAssertEqual(d.removed, 6)
    }

    func testBarSelectionDeltaOrderIndependent() {
        let bars = barSeries(historyPoints())
        let forward = barSelectionDelta(from: bars[0], to: bars[2], in: bars)
        let backward = barSelectionDelta(from: bars[2], to: bars[0], in: bars)
        XCTAssertEqual(forward, backward, "selecting in either order yields the same delta")
        XCTAssertEqual(forward.net, 47, "cum 157 - cum 110")
    }

    func testBarSelectionReadoutFormat() {
        let d = BarSelectionDelta(added: 1240, removed: 50, net: 1190)
        XCTAssertEqual(barSelectionReadout(d),
                       "+1,240 added · \u{2212}50 removed · net +1,190")
        let neg = BarSelectionDelta(added: 10, removed: 60, net: -50)
        XCTAssertEqual(barSelectionReadout(neg),
                       "+10 added · \u{2212}60 removed · net \u{2212}50")
    }

    /// On a DOWNSAMPLED series, intermediate days are dropped so the retained per-day
    /// `added`/`removed` sum can OVERSHOOT the true cumulative endpoint diff. The
    /// readout's net must still equal the cumulative diff (authoritative net), not the
    /// per-day `added − removed`. Regression guard for the old reconciliation hack,
    /// which left `added − removed != net` on an overshoot.
    func testBarSelectionDeltaNetAuthoritativeOnDownsampledOvershoot() {
        let count = 1000   // > barMaxPoints (200) -> downsampled
        let day0 = Date(timeIntervalSince1970: 1_700_000_000)
        // Cumulative climbs slowly (+1/day) but each retained day reports heavy churn
        // (added 100, removed 90 -> per-day net +10). So the per-day sum over a window
        // wildly overshoots the cumulative diff once intermediate days are dropped.
        var cum = 0
        let history = (0..<count).map { i -> CodeStatsPoint in
            cum += 1
            return CodeStatsPoint(date: day0.addingTimeInterval(Double(i) * 86_400),
                                  totalLines: cum, code: cum, comment: 0, blank: 0,
                                  totalFiles: 0, dayAdded: 100, dayRemoved: 90)
        }
        let bars = barSeries(history)
        XCTAssertLessThanOrEqual(bars.count, 200, "series is downsampled")
        let d = barSelectionDelta(from: bars.first!, to: bars.last!, in: bars)
        let cumulativeDiff = bars.last!.cumulativeLines - bars.first!.cumulativeLines
        XCTAssertEqual(d.net, cumulativeDiff, "net == cumulative endpoint diff, not added − removed")
        XCTAssertGreaterThan(d.added - d.removed, d.net,
                             "per-day sum overshoots the cumulative diff (the dropped days)")
        // The readout reflects the authoritative net, not the overshooting per-day sum.
        XCTAssertTrue(barSelectionReadout(d).hasSuffix("net +\(groupedThousands(cumulativeDiff))"))
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
