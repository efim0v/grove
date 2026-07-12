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

    func testLanguageBarsMetricSelectorReSortsAndRescales() {
        // DESC-by-code ≠ DESC-by-files: Swift dominates code, JSON dominates files.
        let s = stats([
            lang("Swift", files: 2, code: 1000, comment: 100, blank: 50),
            lang("JSON", files: 50, code: 100, comment: 0, blank: 0),
        ])
        // Default + explicit .code: Swift first, busiest -> fraction 1.0.
        XCTAssertEqual(languageBars(s).map(\.language), ["Swift", "JSON"])
        XCTAssertEqual(languageBars(s, metric: .code).map(\.language), ["Swift", "JSON"])
        XCTAssertEqual(languageBars(s, metric: .code).first?.fraction, 1.0)

        // .files re-sorts (JSON first) AND re-scales (JSON busiest -> 1.0; Swift 2/50).
        let byFiles = languageBars(s, metric: .files)
        XCTAssertEqual(byFiles.map(\.language), ["JSON", "Swift"])
        XCTAssertEqual(byFiles[0].fraction, 1.0)
        XCTAssertEqual(byFiles[0].metricValue, 50)
        XCTAssertEqual(byFiles[0].metricText, "50")
        XCTAssertEqual(byFiles[1].fraction, 2.0 / 50.0, accuracy: 1e-9)

        // .total uses code+comment+blank: Swift 1150 vs JSON 100 -> Swift first.
        XCTAssertEqual(languageBars(s, metric: .total).map(\.language), ["Swift", "JSON"])
        XCTAssertEqual(languageBars(s, metric: .total).first?.metricValue, 1150)

        // .comment: only Swift has comments -> Swift first, JSON share 0.
        let byComment = languageBars(s, metric: .comment)
        XCTAssertEqual(byComment.map(\.language), ["Swift", "JSON"])
        XCTAssertEqual(byComment[1].metricValue, 0)
        XCTAssertEqual(byComment[1].fraction, 0)
    }

    func testLanguageBarsShareReflectsChosenMetric() {
        let s = stats([
            lang("Swift", files: 3, code: 750),
            lang("Python", files: 1, code: 250),
        ])
        // Code share: 750/1000 = 75% and 250/1000 = 25%.
        let byCode = languageBars(s, metric: .code)
        XCTAssertEqual(byCode[0].shareText, "75%")
        XCTAssertEqual(byCode[1].shareText, "25%")
        XCTAssertEqual(byCode.map(\.share).reduce(0, +), 1.0, accuracy: 1e-9)
        // Files share re-scales: 3/4 = 75%, 1/4 = 25% (Swift still busiest by files).
        let byFiles = languageBars(s, metric: .files)
        XCTAssertEqual(byFiles[0].shareText, "75%")
        XCTAssertEqual(byFiles[1].shareText, "25%")
    }

    func testLanguageBarsTieBreaksByNameStably() {
        // Equal code -> deterministic order by language name (Apple < Banana < Cherry).
        let s = stats([
            lang("Banana", files: 1, code: 100),
            lang("Cherry", files: 1, code: 100),
            lang("Apple", files: 1, code: 100),
        ])
        XCTAssertEqual(languageBars(s, metric: .code).map(\.language), ["Apple", "Banana", "Cherry"])
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

    // MARK: - Period windows

    func testStatsPeriodStartAndDays() {
        XCTAssertEqual(StatsPeriod.allCases.map(\.rawValue), ["7d", "30d", "90d", "180d", "360d"])
        XCTAssertEqual(StatsPeriod.d30.days, 30)
        XCTAssertEqual(StatsPeriod.d180.days, 180)
        XCTAssertEqual(StatsPeriod.d360.days, 360)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(StatsPeriod.d7.start(now: now),
                       now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(StatsPeriod.d360.start(now: now),
                       now.addingTimeInterval(-360 * 86_400))
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

    func testCompactDeltaTriangleRoundsToThousands() {
        // ≥1000 → rounded whole-K with a "K" suffix; sign + direction preserved.
        XCTAssertEqual(compactDeltaTriangle(net: 11_234).label, "▲ +11K")
        XCTAssertEqual(compactDeltaTriangle(net: 11_234).direction, .up)
        XCTAssertEqual(compactDeltaTriangle(net: 11_800).label, "▲ +12K", "rounds to NEAREST thousand")
        XCTAssertEqual(compactDeltaTriangle(net: 4_000).label, "▲ +4K")
        XCTAssertEqual(compactDeltaTriangle(net: -2_400).label, "▼ \u{2212}2K")
        XCTAssertEqual(compactDeltaTriangle(net: -2_400).direction, .down)
        // <1000 → exact value (no K), still signed.
        XCTAssertEqual(compactDeltaTriangle(net: 850).label, "▲ +850")
        XCTAssertEqual(compactDeltaTriangle(net: -320).label, "▼ \u{2212}320")
        // 0 → ±0 flat.
        XCTAssertEqual(compactDeltaTriangle(net: 0).label, "±0")
        XCTAssertEqual(compactDeltaTriangle(net: 0).direction, .flat)
        // Boundary: exactly 1000 → 1K.
        XCTAssertEqual(compactDeltaTriangle(net: 1_000).label, "▲ +1K")
        XCTAssertEqual(compactDeltaTriangle(net: 999).label, "▲ +999")
    }

    // MARK: - Net-lines delta (cumulative-state difference, churn-free)

    func testNetLinesDeltaAggregateStateDifference() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func day(_ back: Int) -> Date { now.addingTimeInterval(-Double(back) * 86_400) }
        // Cumulative codebase size over time (totalLines is carried-forward state).
        let history = [
            CodeStatsPoint(date: day(40), totalLines: 100, code: 100, comment: 0, blank: 0, totalFiles: 0,
                           dayAdded: 100, dayRemoved: 0),   // before a 30d window
            CodeStatsPoint(date: day(20), totalLines: 300, code: 300, comment: 0, blank: 0, totalFiles: 0,
                           dayAdded: 200, dayRemoved: 0),
            CodeStatsPoint(date: day(5), totalLines: 500, code: 500, comment: 0, blank: 0, totalFiles: 0,
                           dayAdded: 200, dayRemoved: 0),
        ]
        // 30d window: size now (500) − size as of (now − 30d) carried-forward = the day(40)
        // point's 100 (last ≤ now−30d) → net 400. Churn-free state difference.
        XCTAssertEqual(netLinesDelta(history, period: .d30, now: now), 400)
        // 7d window: size now (500) − size as of (now − 7d) = day(20)'s 300 → net 200.
        XCTAssertEqual(netLinesDelta(history, period: .d7, now: now), 200)
        // A window wider than all history: baseline is 0 (before the first point) → full 500.
        XCTAssertEqual(netLinesDelta(history, period: .d180, now: now), 500)
    }

    func testNetLinesDeltaIgnoresIntermediateChurn() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func day(_ back: Int) -> Date { now.addingTimeInterval(-Double(back) * 86_400) }
        // The codebase churned heavily mid-window (size went 100→1000→120) but the NET
        // state difference over the window is just end − start = 120 − 100 = 20, NOT the
        // gross churn — a line churned many times counts once.
        let history = [
            CodeStatsPoint(date: day(10), totalLines: 100, code: 100, comment: 0, blank: 0, totalFiles: 0),
            CodeStatsPoint(date: day(6), totalLines: 1000, code: 1000, comment: 0, blank: 0, totalFiles: 0),
            CodeStatsPoint(date: day(2), totalLines: 120, code: 120, comment: 0, blank: 0, totalFiles: 0),
        ]
        // Window start (now − 7d) lands between day(10) and day(6) → baseline 100; now → 120.
        XCTAssertEqual(netLinesDelta(history, period: .d7, now: now), 20)
    }

    func testNetLinesDeltaRepoFromHistoryPositiveAndNegative() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func day(_ back: Int) -> Date { now.addingTimeInterval(-Double(back) * 86_400) }
        // A repo that GREW over the window.
        let grew = [
            RepoHistoryPoint(date: day(20), netLines: 200),
            RepoHistoryPoint(date: day(3), netLines: 350),
        ]
        XCTAssertEqual(netLinesDelta(repo: grew, period: .d7, now: now), 150,
                       "350 − (carried-forward 200 as of now−7d) = 150")
        // A repo that SHRANK over the window → negative net (▼).
        let shrank = [
            RepoHistoryPoint(date: day(20), netLines: 900),
            RepoHistoryPoint(date: day(3), netLines: 600),
        ]
        let net = netLinesDelta(repo: shrank, period: .d7, now: now)
        XCTAssertEqual(net, -300)
        XCTAssertEqual(deltaTriangle(net: net).direction, .down)
    }

    func testNetLinesDeltaEmptyHistoryIsZero() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(netLinesDelta([], period: .d30, now: now), 0)
        XCTAssertEqual(netLinesDelta(repo: [], period: .d30, now: now), 0)
    }

    func testNetLinesDeltaByCategoryTelescopesPerDayNet() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func day(_ back: Int) -> Date { now.addingTimeInterval(-Double(back) * 86_400) }
        let history = [
            CodeStatsPoint(date: day(40), totalLines: 0, code: 0, comment: 0, blank: 0, totalFiles: 0,
                           codeAdded: 1000, codeRemoved: 0, dataAdded: 0, dataRemoved: 0),  // OUT of 30d
            CodeStatsPoint(date: day(20), totalLines: 0, code: 0, comment: 0, blank: 0, totalFiles: 0,
                           codeAdded: 250, codeRemoved: 30, dataAdded: 50, dataRemoved: 10),
            CodeStatsPoint(date: day(5), totalLines: 0, code: 0, comment: 0, blank: 0, totalFiles: 0,
                           codeAdded: 100, codeRemoved: 180, dataAdded: 20, dataRemoved: 5),
        ]
        // 30d window (start > day(40), so the 1000 is excluded): code net = (250−30)+(100−180)
        // = 220 − 80 = 140; data net = (50−10)+(20−5) = 40 + 15 = 55.
        let split = netLinesDeltaByCategory(history, period: .d30, now: now)
        XCTAssertEqual(split.code, 140)
        XCTAssertEqual(split.dataProse, 55)
    }

    // MARK: - Stacked cumulative bars (codebase size over time, by repo)

    private func repoWithHistory(_ name: String, _ points: [RepoHistoryPoint]) -> RepoStats {
        let total = points.map(\.netLines).max() ?? 0
        let cs = CodeStats(totalFiles: 1, totalLines: total, code: total, comment: 0, blank: 0,
                           byLanguage: [], scannedAt: Date(timeIntervalSince1970: 0), skippedBinary: 0)
        return RepoStats(repoPath: "/tmp/\(name)", repoName: name, defaultBranch: "main",
                         stats: cs, history: points, delta: .zero)
    }

    func testStackedRepoSeriesCarryForward() throws {
        let cal = GitStatsService.gmtCalendar
        let now = cal.date(from: DateComponents(year: 2025, month: 6, day: 5, hour: 12))!
        func d(_ day: Int) -> Date { cal.date(from: DateComponents(year: 2025, month: 6, day: day))! }
        // Repo A: net 100 on day 1, net 300 on day 3. On day 2 it must carry 100 forward.
        let a = repoWithHistory("A", [
            RepoHistoryPoint(date: d(1), netLines: 100),
            RepoHistoryPoint(date: d(3), netLines: 300),
        ])
        let bars = stackedRepoSeries([a], daysBack: 4, now: now)   // window June 1…5
        func bar(_ day: Int) -> StackedDayBar { bars.first { $0.date == d(day) }! }
        XCTAssertEqual(bar(1).total, 100)
        XCTAssertEqual(bar(2).total, 100, "carries day-1 value forward on a no-commit day")
        XCTAssertEqual(bar(3).total, 300)
        XCTAssertEqual(bar(4).total, 300, "carries day-3 value forward")
        XCTAssertEqual(bar(5).total, 300)
    }

    func testStackedRepoSeriesAbsentBeforeFirstCommit() {
        let cal = GitStatsService.gmtCalendar
        let now = cal.date(from: DateComponents(year: 2025, month: 6, day: 6, hour: 12))!
        func d(_ day: Int) -> Date { cal.date(from: DateComponents(year: 2025, month: 6, day: day))! }
        // First commit on day 5 → days 1…4 contribute 0 (no segment for this repo).
        let a = repoWithHistory("A", [RepoHistoryPoint(date: d(5), netLines: 400)])
        let bars = stackedRepoSeries([a], daysBack: 5, now: now)   // window June 1…6
        let early = bars.first { $0.date == d(2) }!
        XCTAssertEqual(early.total, 0)
        XCTAssertTrue(early.segments.isEmpty, "repo absent before its first commit = no segment")
        let after = bars.first { $0.date == d(5) }!
        XCTAssertEqual(after.total, 400)
        XCTAssertEqual(after.segments.map(\.repoName), ["A"])
    }

    func testStackedRepoSeriesOrderingBiggestAtBottom() {
        let cal = GitStatsService.gmtCalendar
        let now = cal.date(from: DateComponents(year: 2025, month: 6, day: 2, hour: 12))!
        func d(_ day: Int) -> Date { cal.date(from: DateComponents(year: 2025, month: 6, day: day))! }
        let big = repoWithHistory("zeta", [RepoHistoryPoint(date: d(1), netLines: 900)])
        let small = repoWithHistory("alpha", [RepoHistoryPoint(date: d(1), netLines: 100)])
        let tie = repoWithHistory("beta", [RepoHistoryPoint(date: d(1), netLines: 100)])
        let bars = stackedRepoSeries([small, big, tie], daysBack: 1, now: now)
        let bar = bars.first { $0.date == d(2) }!
        // Biggest first; the two 100-line repos tie and sort by name (alpha < beta).
        XCTAssertEqual(bar.segments.map(\.repoName), ["zeta", "alpha", "beta"])
        XCTAssertEqual(bar.segments.map(\.lines), [900, 100, 100])
        XCTAssertEqual(bar.total, 1100)
    }

    func testStackedRepoSeriesTotalsAndDayFill() {
        let cal = GitStatsService.gmtCalendar
        let now = cal.date(from: DateComponents(year: 2025, month: 6, day: 10, hour: 12))!
        func d(_ day: Int) -> Date { cal.date(from: DateComponents(year: 2025, month: 6, day: day))! }
        let a = repoWithHistory("A", [RepoHistoryPoint(date: d(2), netLines: 200)])
        let b = repoWithHistory("B", [RepoHistoryPoint(date: d(4), netLines: 50)])
        let bars = stackedRepoSeries([a, b], daysBack: 9, now: now)   // June 1…10 = 10 bars
        XCTAssertEqual(bars.count, 10, "window is fully day-filled: daysBack + 1")
        // Strictly consecutive calendar days, oldest first.
        for i in 1..<bars.count {
            XCTAssertEqual(bars[i].date.timeIntervalSince(bars[i - 1].date), 86_400, accuracy: 1)
        }
        // total always equals the sum of its segments.
        for bar in bars { XCTAssertEqual(bar.total, bar.segments.reduce(0) { $0 + $1.lines }) }
        // Once both repos exist (day ≥ 4) the day's total is 200 + 50 = 250.
        XCTAssertEqual(bars.first { $0.date == d(6) }!.total, 250)
    }

    func testStackedRepoSeriesIsMonotonicOnAllAdditions() {
        let cal = GitStatsService.gmtCalendar
        let now = cal.date(from: DateComponents(year: 2025, month: 6, day: 6, hour: 12))!
        func d(_ day: Int) -> Date { cal.date(from: DateComponents(year: 2025, month: 6, day: day))! }
        // Two repos whose cumulative netLines only ever rise → the stacked total never
        // decreases left→right (the codebase-size chart grows).
        let a = repoWithHistory("A", [
            RepoHistoryPoint(date: d(1), netLines: 100),
            RepoHistoryPoint(date: d(3), netLines: 250),
            RepoHistoryPoint(date: d(5), netLines: 400),
        ])
        let b = repoWithHistory("B", [
            RepoHistoryPoint(date: d(2), netLines: 50),
            RepoHistoryPoint(date: d(4), netLines: 90),
        ])
        let bars = stackedRepoSeries([a, b], daysBack: 5, now: now)
        let totals = bars.map(\.total)
        for i in 1..<totals.count {
            XCTAssertGreaterThanOrEqual(totals[i], totals[i - 1], "all-additions ⇒ non-decreasing")
        }
        XCTAssertEqual(totals.last, 490, "final size = A(400) + B(90)")
    }

    func testStackedRepoSeriesCapAndDaysBackClamp() {
        let cal = GitStatsService.gmtCalendar
        let now = cal.date(from: DateComponents(year: 2025, month: 6, day: 30, hour: 12))!
        let a = repoWithHistory("A", [
            RepoHistoryPoint(date: cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!,
                             netLines: 100),
        ])
        // daysBack beyond the 1-year cap clamps to 365 back + today = 366 bars.
        let capped = stackedRepoSeries([a], daysBack: 10_000, now: now)
        XCTAssertEqual(capped.count, 366, "daysBack clamps to the 1-year cap")
        // The full-year request has more days than the default viewport (scroll-back room).
        XCTAssertGreaterThan(capped.count, stackedDefaultVisibleDays)
        // A small explicit window day-fills exactly its span (7 back + today = 8).
        let week = stackedRepoSeries([a], daysBack: 7, now: now)
        XCTAssertEqual(week.count, 8)
    }

    func testStackedRepoSeriesNegativeNetLinesClampedToZero() {
        let cal = GitStatsService.gmtCalendar
        let now = cal.date(from: DateComponents(year: 2025, month: 6, day: 2, hour: 12))!
        func d(_ day: Int) -> Date { cal.date(from: DateComponents(year: 2025, month: 6, day: day))! }
        // A pathological negative cumulative (shouldn't happen, but be safe) draws as 0.
        let a = repoWithHistory("A", [RepoHistoryPoint(date: d(1), netLines: -50)])
        let bar = stackedRepoSeries([a], daysBack: 1, now: now).first { $0.date == d(2) }!
        XCTAssertEqual(bar.total, 0)
        XCTAssertTrue(bar.segments.isEmpty, "a repo can't show negative lines on screen")
    }

    func testStackedPeakFlooredAtOne() {
        let cal = GitStatsService.gmtCalendar
        func d(_ day: Int) -> Date { cal.date(from: DateComponents(year: 2025, month: 6, day: day))! }
        let bars = [
            StackedDayBar(date: d(1), segments: [StackedSegment(repoName: "A", lines: 100)]),
            StackedDayBar(date: d(2), segments: [StackedSegment(repoName: "A", lines: 350)]),
        ]
        XCTAssertEqual(stackedPeak(bars), 350)
        // All-zero / empty series floors at 1 so the view never divides by zero.
        XCTAssertEqual(stackedPeak([StackedDayBar(date: d(1), segments: [])]), 1)
        XCTAssertEqual(stackedPeak([]), 1)
    }

    func testStackedSegmentHeightProportionalAndFloored() {
        // 200-line repo against a 400 peak over a 120pt plot = 60pt.
        XCTAssertEqual(stackedSegmentHeight(lines: 200, peak: 400, height: 120), 60, accuracy: 0.001)
        // The peak repo fills the whole plot.
        XCTAssertEqual(stackedSegmentHeight(lines: 400, peak: 400, height: 120), 120, accuracy: 0.001)
        // A tiny-but-present repo floors at 1px so it isn't invisible.
        XCTAssertEqual(stackedSegmentHeight(lines: 1, peak: 1_000_000, height: 120), 1)
        // A zero-line repo draws nothing.
        XCTAssertEqual(stackedSegmentHeight(lines: 0, peak: 400, height: 120), 0)
    }

    func testStackedDayReadoutFormatsTotal() {
        let cal = GitStatsService.gmtCalendar
        let day = cal.date(from: DateComponents(year: 2026, month: 6, day: 14))!
        let bar = StackedDayBar(date: day, segments: [
            StackedSegment(repoName: "media-pipeline", lines: 31_400),
            StackedSegment(repoName: "media-upload", lines: 17_390),
        ])
        XCTAssertEqual(stackedDayReadout(bar), "Jun 14 · 48,790 lines")
        // A day before any code reads "no code yet".
        let empty = StackedDayBar(date: day, segments: [])
        XCTAssertEqual(stackedDayReadout(empty), "Jun 14 · no code yet")
        // The short GMT date formatter (POSIX, GMT) backing the readout.
        XCTAssertEqual(shortDayDateText(day), "Jun 14")
    }

    // MARK: - Stacked chart axes (month X-labels + nice Y-ticks)

    private func emptyBar(_ date: Date) -> StackedDayBar {
        StackedDayBar(date: date, segments: [])
    }

    func testMonthLabelPositionsOneLabelPerMonthBoundary() {
        let cal = GitStatsService.gmtCalendar
        func d(_ m: Int, _ day: Int) -> Date {
            cal.date(from: DateComponents(year: 2025, month: m, day: day))!
        }
        // May 30, May 31, Jun 1, Jun 2, Jul 1 -> labels at the May (idx 0), Jun (idx 2),
        // and Jul (idx 4) boundaries only — deduped within a month.
        let bars = [d(5, 30), d(5, 31), d(6, 1), d(6, 2), d(7, 1)].map(emptyBar)
        let labels = monthLabelPositions(bars, slotWidth: 4)
        XCTAssertEqual(labels.map(\.label), ["May", "Jun", "Jul"])
        XCTAssertEqual(labels.map(\.x), [0, 8, 16])   // idx 0·4, 2·4, 4·4
        XCTAssertEqual(labels[0].id, 0)
    }

    func testMonthLabelPositionsIndexZeroAlwaysEmits() {
        let cal = GitStatsService.gmtCalendar
        func d(_ day: Int) -> Date { cal.date(from: DateComponents(year: 2025, month: 6, day: day))! }
        // A series entirely WITHIN one month still labels that month once, at x = 0.
        let labels = monthLabelPositions([d(10), d(11), d(12)].map(emptyBar), slotWidth: 5)
        XCTAssertEqual(labels.map(\.label), ["Jun"])
        XCTAssertEqual(labels.map(\.x), [0])
    }

    func testMonthLabelPositionsDisambiguatesAcrossYears() {
        let cal = GitStatsService.gmtCalendar
        // Dec 2025 -> Jan 2026 -> Dec 2026 spans >1 calendar year, so labels carry the year.
        let bars = [
            cal.date(from: DateComponents(year: 2025, month: 12, day: 31))!,
            cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!,
            cal.date(from: DateComponents(year: 2026, month: 12, day: 1))!,
        ].map(emptyBar)
        let labels = monthLabelPositions(bars, slotWidth: 4)
        XCTAssertEqual(labels.map(\.label), ["Dec '25", "Jan '26", "Dec '26"])
    }

    func testMonthLabelPositionsEmpty() {
        XCTAssertTrue(monthLabelPositions([], slotWidth: 4).isEmpty)
    }

    func testNiceTicksRoundAndCoverThePeak() {
        let ticks = niceTicks(peak: 48_790)
        XCTAssertEqual(ticks.first, 0, "always starts at 0")
        XCTAssertGreaterThanOrEqual(ticks.last!, 48_790, "top tick covers the tallest bar")
        XCTAssertLessThanOrEqual(ticks.count, 5, "3–4 intervals -> ≤5 ticks")
        // Strictly increasing.
        for i in 1..<ticks.count { XCTAssertGreaterThan(ticks[i], ticks[i - 1]) }
        // Even, round step (a 1/2/5 × 10ⁿ nice number); peak 48,790 over 4 intervals
        // -> rawStep ~12,198 -> nice step 20,000 -> [0, 20k, 40k, 60k].
        XCTAssertEqual(ticks, [0, 20_000, 40_000, 60_000])
        let step = ticks[1] - ticks[0]
        for i in 1..<ticks.count {
            XCTAssertEqual(ticks[i] - ticks[i - 1], step, "uniform step between ticks")
        }
    }

    func testNiceTicksEdgeCases() {
        XCTAssertEqual(niceTicks(peak: 0), [0], "no data -> single zero tick")
        XCTAssertEqual(niceTicks(peak: -5), [0], "negative guarded to a single zero tick")
        // Small peak -> small clean ticks, still covering the peak.
        let small = niceTicks(peak: 3)
        XCTAssertEqual(small.first, 0)
        XCTAssertGreaterThanOrEqual(small.last!, 3)
        XCTAssertLessThanOrEqual(small.count, 5)
        // Large peak stays round (1/2/5 × 10ⁿ) and covers it.
        let big = niceTicks(peak: 1_200_000)
        XCTAssertEqual(big.first, 0)
        XCTAssertGreaterThanOrEqual(big.last!, 1_200_000)
        XCTAssertLessThanOrEqual(big.count, 5)
        XCTAssertEqual(big, [0, 500_000, 1_000_000, 1_500_000])
    }

    // MARK: - Per-repo color ramp

    func testRepoColorSingleRepoIsPrimary() {
        XCTAssertEqual(repoColor(index: 0, count: 1), Palette.primary)
    }

    func testRepoColorSpreadAcrossRampAndDistinct() {
        // 3 repos spread across the heat ramp: first = primary (t=0), last = negative (t=1),
        // and all three are visibly distinct.
        let c0 = repoColor(index: 0, count: 3)
        let c1 = repoColor(index: 1, count: 3)
        let c2 = repoColor(index: 2, count: 3)
        XCTAssertEqual(c0, Palette.heat(0))
        XCTAssertEqual(c2, Palette.heat(1))
        XCTAssertNotEqual(c0, c1)
        XCTAssertNotEqual(c1, c2)
        XCTAssertNotEqual(c0, c2)
        // Out-of-range index is clamped (no crash, stays in palette).
        XCTAssertEqual(repoColor(index: 99, count: 3), repoColor(index: 2, count: 3))
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
        // NET delta = (cumulative netLines as of now) − (as of now − 7d) = 240 − 0 = 240.
        XCTAssertEqual(cards[0].net, 240)
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
        // NET delta = netLines as of now (510) − as of now−7d (the 40d-back point's 500) = 10.
        // The pre-window growth (the old day's 500) is the baseline, not counted in the window.
        XCTAssertEqual(cards[0].net, 10, "only in-window growth counts; old baseline excluded")
    }

    // MARK: - Repo scope (shared controls strip filters)

    /// A repo whose `stats.byLanguage` is the given list (so a scoped Languages card reads
    /// it), with an explicit per-day classified history.
    private func repoStat(_ name: String, langs: [LanguageStats],
                          history: [RepoHistoryPoint]) -> RepoStats {
        let totalLines = langs.reduce(0) { $0 + $1.total }
        let cs = CodeStats(totalFiles: langs.reduce(0) { $0 + $1.files },
                           totalLines: totalLines,
                           code: langs.reduce(0) { $0 + $1.code },
                           comment: langs.reduce(0) { $0 + $1.comment },
                           blank: langs.reduce(0) { $0 + $1.blank },
                           byLanguage: langs,
                           scannedAt: Date(timeIntervalSince1970: 0), skippedBinary: 0)
        return RepoStats(repoPath: "/tmp/\(name)", repoName: name, defaultBranch: "main",
                         stats: cs, history: history, delta: .zero)
    }

    func testRepoScopeOptionsAllFirstThenSortedByName() {
        let z = repoStat("zebra", langs: [], history: [])
        let a = repoStat("alpha", langs: [], history: [])
        let options = repoScopeOptions([z, a])
        XCTAssertEqual(options.map(\.label), ["All repos", "alpha", "zebra"])
        XCTAssertNil(options[0].name, "first option is All (nil name)")
        XCTAssertEqual(options[1].name, "alpha")
        XCTAssertEqual(options[0].id, "", "All's id is the empty token")
        XCTAssertEqual(options[1].id, "alpha")
    }

    func testFilterAggregateByRepoNilReturnsAggregate() {
        let aggregate = stats([lang("Swift", files: 3, code: 300)])
        let repo = repoStat("a", langs: [lang("Go", files: 1, code: 10)], history: [])
        XCTAssertEqual(filterAggregateByRepo(aggregate, repos: [repo], repoName: nil), aggregate)
    }

    func testFilterAggregateByRepoSelectsRepoStats() {
        let aggregate = stats([lang("Swift", files: 3, code: 300)])
        let repoLangs = [lang("Go", files: 1, code: 10, comment: 2, blank: 1)]
        let repo = repoStat("a", langs: repoLangs, history: [])
        let scoped = filterAggregateByRepo(aggregate, repos: [repo], repoName: "a")
        XCTAssertEqual(scoped.byLanguage, repoLangs, "scoped Languages come from the repo")
        XCTAssertEqual(scoped.totalLines, 13)
    }

    func testFilterAggregateByRepoUnknownFallsBackToAggregate() {
        let aggregate = stats([lang("Swift", files: 3, code: 300)])
        let repo = repoStat("a", langs: [lang("Go", files: 1, code: 10)], history: [])
        // A stale selection that no longer matches any repo must NOT blank the screen.
        XCTAssertEqual(filterAggregateByRepo(aggregate, repos: [repo], repoName: "gone"),
                       aggregate)
    }

    func testFilterRepoStatsScopesToOneOrAll() {
        let a = repoStat("alpha", langs: [], history: [])
        let b = repoStat("beta", langs: [], history: [])
        XCTAssertEqual(filterRepoStats([a, b], repoName: nil).map(\.repoName), ["alpha", "beta"])
        XCTAssertEqual(filterRepoStats([a, b], repoName: "beta").map(\.repoName), ["beta"])
        // Unknown name → all (never an empty Repositories/chart card).
        XCTAssertEqual(filterRepoStats([a, b], repoName: "gone").map(\.repoName),
                       ["alpha", "beta"])
    }

    func testFilterHistoryByRepoNilReturnsAggregateHistory() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let agg = [CodeStatsPoint(date: now, totalLines: 500, code: 400, comment: 50,
                                  blank: 50, totalFiles: 9)]
        let repo = repoStat("a", langs: [], history: [])
        XCTAssertEqual(filterHistoryByRepo(agg, repos: [repo], repoName: nil), agg)
    }

    func testFilterHistoryByRepoProjectsRepoNetDelta() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day = now.addingTimeInterval(-2 * 86_400)
        // A repo grew 240 net (180 code, 60 data) on a day inside the 7d window.
        let repo = repoStat("a", langs: [], history: [
            RepoHistoryPoint(date: day, netLines: 240, dayAdded: 300, dayRemoved: 60,
                             codeAdded: 220, codeRemoved: 40, dataAdded: 80, dataRemoved: 20),
        ])
        let scoped = filterHistoryByRepo([], repos: [repo], repoName: "a")
        // The cumulative netLines (240) becomes totalLines, so the aggregate net delta reads
        // the repo's own growth over the window.
        XCTAssertEqual(netLinesDelta(scoped, period: .d7, now: now), 240)
        // The per-day classified churn carries through, so the per-category deltas split.
        let byCat = netLinesDeltaByCategory(scoped, period: .d7, now: now)
        XCTAssertEqual(byCat.code, 220 - 40)       // codeAdded − codeRemoved
        XCTAssertEqual(byCat.dataProse, 80 - 20)   // dataAdded − dataRemoved
    }

    func testFilterHistoryByRepoClampsNegativeNetToZero() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day = now.addingTimeInterval(-1 * 86_400)
        let repo = repoStat("a", langs: [], history: [
            RepoHistoryPoint(date: day, netLines: -30),
        ])
        let scoped = filterHistoryByRepo([], repos: [repo], repoName: "a")
        XCTAssertEqual(scoped.first?.totalLines, 0, "negative cumulative net clamps to 0")
    }

    // MARK: - Memo caches (SeriesCache + RepoCellsCache)

    // Helper: a minimal RepoStats with a single history point.
    private func miniRepo(_ name: String, scannedAt: Date = Date(timeIntervalSince1970: 1_000_000),
                          netLines: Int = 100) -> RepoStats {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cs = CodeStats(totalFiles: 1, totalLines: netLines, code: netLines, comment: 0, blank: 0,
                           byLanguage: [], scannedAt: scannedAt, skippedBinary: 0)
        return RepoStats(repoPath: "/tmp/\(name)", repoName: name, defaultBranch: "main",
                         stats: cs,
                         history: [RepoHistoryPoint(date: now.addingTimeInterval(-86_400),
                                                    netLines: netLines)],
                         delta: .zero)
    }

    // MARK: SeriesCache

    func testSeriesCacheSameKeyReturnsCachedValueWithoutRecompute() {
        // Arrange: a cache and an input set. Track how many times compute was called.
        let cache = SeriesCache()
        var computeCount = 0
        let repos = [miniRepo("A")]
        let scannedAt = Date(timeIntervalSince1970: 1_000_000)
        let scope = Set(repos.map(\.repoPath))
        let projectID = UUID()
        let now = Date(timeIntervalSince1970: 1_100_000)

        // Act: fetch twice with the same key.
        let first = cache.bars(projectID: projectID, scope: scope, scannedAt: scannedAt,
                               metric: .lines, now: now, repos: repos) { r, n in
            computeCount += 1
            return stackedRepoSeries(r, daysBack: stackedBarMaxDaysBack, metric: .lines, now: n)
        }
        let second = cache.bars(projectID: projectID, scope: scope, scannedAt: scannedAt,
                                metric: .lines, now: now, repos: repos) { r, n in
            computeCount += 1
            return stackedRepoSeries(r, daysBack: stackedBarMaxDaysBack, metric: .lines, now: n)
        }

        // Assert: computed exactly once; both results are identical.
        XCTAssertEqual(computeCount, 1, "second call must be a cache hit — no recompute")
        XCTAssertEqual(first, second)
    }

    func testSeriesCacheRecomputesOnNewScannedAt() {
        let cache = SeriesCache()
        var computeCount = 0
        let repos = [miniRepo("A")]
        let scope = Set(repos.map(\.repoPath))
        let projectID = UUID()
        let now = Date(timeIntervalSince1970: 1_100_000)

        let t1 = Date(timeIntervalSince1970: 1_000_000)
        let t2 = Date(timeIntervalSince1970: 1_001_000)   // different scannedAt → cache miss

        _ = cache.bars(projectID: projectID, scope: scope, scannedAt: t1, metric: .lines,
                       now: now, repos: repos) { r, n in
            computeCount += 1
            return stackedRepoSeries(r, daysBack: stackedBarMaxDaysBack, metric: .lines, now: n)
        }
        _ = cache.bars(projectID: projectID, scope: scope, scannedAt: t2, metric: .lines,
                       now: now, repos: repos) { r, n in
            computeCount += 1
            return stackedRepoSeries(r, daysBack: stackedBarMaxDaysBack, metric: .lines, now: n)
        }

        XCTAssertEqual(computeCount, 2, "changed scannedAt must invalidate the cache")
    }

    func testSeriesCacheRecomputesOnChangedMetric() {
        let cache = SeriesCache()
        var computeCount = 0
        let repos = [miniRepo("A")]
        let scope = Set(repos.map(\.repoPath))
        let projectID = UUID()
        let scannedAt = Date(timeIntervalSince1970: 1_000_000)
        let now = Date(timeIntervalSince1970: 1_100_000)

        _ = cache.bars(projectID: projectID, scope: scope, scannedAt: scannedAt, metric: .lines,
                       now: now, repos: repos) { r, n in
            computeCount += 1
            return stackedRepoSeries(r, daysBack: stackedBarMaxDaysBack, metric: .lines, now: n)
        }
        _ = cache.bars(projectID: projectID, scope: scope, scannedAt: scannedAt, metric: .code,
                       now: now, repos: repos) { r, n in
            computeCount += 1
            return stackedRepoSeries(r, daysBack: stackedBarMaxDaysBack, metric: .code, now: n)
        }

        XCTAssertEqual(computeCount, 2, "changed metric must invalidate the cache")
    }

    func testSeriesCacheRecomputesOnChangedScope() {
        let cache = SeriesCache()
        var computeCount = 0
        let repoA = miniRepo("A")
        let repoB = miniRepo("B")
        let projectID = UUID()
        let scannedAt = Date(timeIntervalSince1970: 1_000_000)
        let now = Date(timeIntervalSince1970: 1_100_000)

        _ = cache.bars(projectID: projectID, scope: Set([repoA.repoPath]), scannedAt: scannedAt,
                       metric: .lines, now: now, repos: [repoA]) { r, n in
            computeCount += 1
            return stackedRepoSeries(r, daysBack: stackedBarMaxDaysBack, metric: .lines, now: n)
        }
        _ = cache.bars(projectID: projectID, scope: Set([repoA.repoPath, repoB.repoPath]),
                       scannedAt: scannedAt, metric: .lines, now: now, repos: [repoA, repoB]) { r, n in
            computeCount += 1
            return stackedRepoSeries(r, daysBack: stackedBarMaxDaysBack, metric: .lines, now: n)
        }

        XCTAssertEqual(computeCount, 2, "changed scope (added repo) must invalidate the cache")
    }

    // MARK: RepoCellsCache

    func testRepoCellsCacheSameKeyReturnsCachedValueWithoutRecompute() {
        let cache = RepoCellsCache()
        var computeCount = 0
        let repos = [miniRepo("A")]
        let scope = Set(repos.map(\.repoPath))
        let projectID = UUID()
        let scannedAt = Date(timeIntervalSince1970: 1_000_000)
        let now = Date(timeIntervalSince1970: 1_100_000)
        let period = StatsPeriod.d30

        let first = cache.cells(projectID: projectID, scope: scope, scannedAt: scannedAt,
                                period: period, now: now, repos: repos) { r, n in
            computeCount += 1
            return repoCells(r, period: period, now: n)
        }
        let second = cache.cells(projectID: projectID, scope: scope, scannedAt: scannedAt,
                                 period: period, now: now, repos: repos) { r, n in
            computeCount += 1
            return repoCells(r, period: period, now: n)
        }

        XCTAssertEqual(computeCount, 1, "second call must be a cache hit — no recompute")
        XCTAssertEqual(first, second)
    }

    func testRepoCellsCacheRecomputesOnChangedPeriod() {
        let cache = RepoCellsCache()
        var computeCount = 0
        let repos = [miniRepo("A")]
        let scope = Set(repos.map(\.repoPath))
        let projectID = UUID()
        let scannedAt = Date(timeIntervalSince1970: 1_000_000)
        let now = Date(timeIntervalSince1970: 1_100_000)

        _ = cache.cells(projectID: projectID, scope: scope, scannedAt: scannedAt,
                        period: .d7, now: now, repos: repos) { r, n in
            computeCount += 1
            return repoCells(r, period: .d7, now: n)
        }
        _ = cache.cells(projectID: projectID, scope: scope, scannedAt: scannedAt,
                        period: .d30, now: now, repos: repos) { r, n in
            computeCount += 1
            return repoCells(r, period: .d30, now: n)
        }

        XCTAssertEqual(computeCount, 2, "changed period must invalidate the RepoCellsCache")
    }

    func testRepoCellsCacheRecomputesOnChangedScannedAt() {
        let cache = RepoCellsCache()
        var computeCount = 0
        let repos = [miniRepo("A")]
        let scope = Set(repos.map(\.repoPath))
        let projectID = UUID()
        let now = Date(timeIntervalSince1970: 1_100_000)
        let period = StatsPeriod.d30

        _ = cache.cells(projectID: projectID, scope: scope,
                        scannedAt: Date(timeIntervalSince1970: 1_000_000),
                        period: period, now: now, repos: repos) { r, n in
            computeCount += 1; return repoCells(r, period: period, now: n)
        }
        _ = cache.cells(projectID: projectID, scope: scope,
                        scannedAt: Date(timeIntervalSince1970: 1_001_000),
                        period: period, now: now, repos: repos) { r, n in
            computeCount += 1; return repoCells(r, period: period, now: n)
        }

        XCTAssertEqual(computeCount, 2, "changed scannedAt must invalidate RepoCellsCache")
    }

    // MARK: - tokensPerNetLine (Phase 5D)

    /// Helper: make a CodeStatsPoint on a UTC calendar day (seconds since epoch at midnight UTC).
    private func csp(dayOffset: Int, from base: Date, dayAdded: Int,
                     totalLines: Int = 0) -> CodeStatsPoint {
        let cal = utcCal
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: base))!
        return CodeStatsPoint(date: day, totalLines: totalLines,
                              code: 0, comment: 0, blank: 0, totalFiles: 0,
                              dayAdded: dayAdded, dayRemoved: 0)
    }

    private var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Helper: make a DayUsage at midnight UTC for a given day offset.
    private func du(dayOffset: Int, from base: Date,
                    input: Int, output: Int, cache: Int = 0) -> DayUsage {
        let cal = utcCal
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: base))!
        return DayUsage(day: day, inputTokens: input, outputTokens: output, cacheTokens: cache)
    }

    /// Base date for the fixture: 2026-06-18T00:00:00Z (before the degraded cutoff).
    private var base: Date { Date(timeIntervalSince1970: 1_781_740_800) } // 2026-06-18 UTC

    /// Two accounts, two cwds, three days of tokens + code history.
    /// Day 0: 100 tokens (acct1/cwdA) + 200 tokens (acct2/cwdB) = 300 cumTokens; 50 netLines → ratio 600.
    /// Day 1: +300 tokens (acct1/cwdA) = 600 cumTokens; +50 netLines = 100 → ratio 600.
    /// Day 2: +0 tokens; +200 netLines = 300 → ratio 200.
    func testTokensPerNetLineCumulativeRatio() {
        let cwd1 = "/ws/proj"
        let cwd2 = "/ws/proj/worker"   // prefix-matches the project (hasPrefix cwd1 + "/")
        let tokensByAcct: [[String: [DayUsage]]] = [
            // Account 1: cwd1 gets tokens on day 0 and day 1.
            [cwd1: [du(dayOffset: 0, from: base, input: 80, output: 20),
                    du(dayOffset: 1, from: base, input: 200, output: 100)]],
            // Account 2: cwd2 gets tokens on day 0 only.
            [cwd2: [du(dayOffset: 0, from: base, input: 150, output: 50)]],
        ]
        let history: [CodeStatsPoint] = [
            csp(dayOffset: 0, from: base, dayAdded: 50),
            csp(dayOffset: 1, from: base, dayAdded: 50),
            csp(dayOffset: 2, from: base, dayAdded: 200),
        ]
        let projectCwds = [cwd1]
        // 'now' is day 2 (not degraded).
        let now = utcCal.date(byAdding: .day, value: 2, to: utcCal.startOfDay(for: base))!

        let points = tokensPerNetLine(
            tokenDailyByCwdPerAccount: tokensByAcct,
            projectCwds: projectCwds,
            codeHistory: history,
            now: now
        )

        XCTAssertEqual(points.count, 3, "one point per calendar day")

        // Day 0: cumTokens=300 (100+200), cumLines=50 → 300/50×100 = 600.
        let d0 = points[0]
        XCTAssertEqual(d0.tokensPer100Lines, 600.0, accuracy: 0.01)
        XCTAssertFalse(d0.degraded, "day 0 is before the cutoff")

        // Day 1: cumTokens=600 (300+300), cumLines=100 → 600/100×100 = 600.
        let d1 = points[1]
        XCTAssertEqual(d1.tokensPer100Lines, 600.0, accuracy: 0.01)
        XCTAssertFalse(d1.degraded)

        // Day 2: cumTokens=600 (no new tokens), cumLines=300 → 600/300×100 = 200.
        let d2 = points[2]
        XCTAssertEqual(d2.tokensPer100Lines, 200.0, accuracy: 0.01)
        XCTAssertFalse(d2.degraded)
    }

    /// A day with cumLines=0 must yield ratio 0 (no divide-by-zero).
    func testTokensPerNetLineZeroCumLinesYieldsZeroRatio() {
        let tokensByAcct: [[String: [DayUsage]]] = [
            ["/ws/p": [du(dayOffset: 0, from: base, input: 500, output: 0)]],
        ]
        let history: [CodeStatsPoint] = []   // no lines added → cumLines stays 0
        let points = tokensPerNetLine(
            tokenDailyByCwdPerAccount: tokensByAcct,
            projectCwds: ["/ws/p"],
            codeHistory: history,
            now: utcCal.startOfDay(for: base)
        )
        XCTAssertFalse(points.isEmpty)
        XCTAssertEqual(points[0].tokensPer100Lines, 0.0, "zero cumLines → ratio 0 (no NaN/inf)")
    }

    /// Days past 2026-06-20 are marked degraded.
    func testTokensPerNetLineDegradedFlagAfterCutoff() {
        // 2026-06-23T00:00:00Z — a day clearly after the 2026-06-20 cutoff.
        let cutoffPlus3 = Date(timeIntervalSince1970: 1_782_172_800)
        let history: [CodeStatsPoint] = [
            csp(dayOffset: 0, from: cutoffPlus3, dayAdded: 100),
        ]
        let points = tokensPerNetLine(
            tokenDailyByCwdPerAccount: [],
            projectCwds: [],
            codeHistory: history,
            now: cutoffPlus3
        )
        XCTAssertFalse(points.isEmpty)
        XCTAssertTrue(points[0].degraded, "day after 2026-06-20 must be marked degraded")
    }

    /// Only cwds that prefix-match the project's cwds contribute tokens.
    func testTokensPerNetLineOnlyPrefixMatchingCwdsCount() {
        let cwd = "/ws/proj"
        let unrelated = "/ws/other"
        let tokensByAcct: [[String: [DayUsage]]] = [
            [cwd: [du(dayOffset: 0, from: base, input: 100, output: 0)],
             unrelated: [du(dayOffset: 0, from: base, input: 9999, output: 0)]],
        ]
        let history: [CodeStatsPoint] = [csp(dayOffset: 0, from: base, dayAdded: 100)]
        let points = tokensPerNetLine(
            tokenDailyByCwdPerAccount: tokensByAcct,
            projectCwds: [cwd],
            codeHistory: history,
            now: utcCal.startOfDay(for: base)
        )
        // Only 100 tokens (cwd match), not 10099. ratio = 100/100*100 = 100.
        XCTAssertEqual(points[0].tokensPer100Lines, 100.0, accuracy: 0.01)
    }
}
