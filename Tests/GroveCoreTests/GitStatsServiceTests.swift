import Foundation
import XCTest
@testable import GroveCore

/// Exercises GitStatsService against SYNTHETIC temp git repos built per test. Every
/// repo is created under FileManager.temporaryDirectory and never touches the user's
/// real filesystem. Author/committer dates are pinned for deterministic history.
final class GitStatsServiceTests: XCTestCase {
    private let service = GitStatsService()

    override func setUpWithError() throws {
        // Skip the whole suite when git is unavailable (matches GitWorktreeTests style).
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["git", "--version"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try? probe.run()
        probe.waitUntilExit()
        try XCTSkipUnless(probe.terminationStatus == 0, "git not available")
    }

    // MARK: - Local fixture helpers (committed at a pinned date)

    /// git emits symlink-resolved paths (/private/var/... on macOS); normalize both
    /// sides when comparing fixture paths to discovered repo paths.
    private func norm(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func sh(_ command: String, cwd: URL? = nil) throws {
        _ = try Fixture.sh(command, cwd: cwd)
    }

    /// Writes `content` to `repo/rel`, creating intermediate dirs.
    private func write(_ content: String, to rel: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `git add -A && git commit` at a fixed author+committer date (ISO8601).
    private func commit(_ message: String, in repo: URL, date: String) throws {
        let env = "GIT_AUTHOR_DATE='\(date)' GIT_COMMITTER_DATE='\(date)'"
        try sh("\(env) git -C \(shellQuote(repo.path)) add -A && \(env) git -C \(shellQuote(repo.path)) commit -qm \(shellQuote(message))")
    }

    private func info(_ url: URL) -> RepoInfo {
        RepoInfo(path: url.path, dirName: url.lastPathComponent)
    }

    /// A bare empty repo (no base commit), so we can control the FIRST commit's date.
    private func emptyRepo(in parent: URL, name: String, branch: String = "main") throws -> URL {
        let repo = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try sh("git init -q -b \(shellQuote(branch)) \(shellQuote(repo.path))")
        try sh("git -C \(shellQuote(repo.path)) config user.email t@t && git -C \(shellQuote(repo.path)) config user.name t")
        return repo
    }

    /// ISO8601 instants on three distinct GMT days, plus a fixed "now".
    private let day1 = "2025-01-01T12:00:00Z"
    private let day2 = "2025-01-02T12:00:00Z"
    private let day3 = "2025-01-03T12:00:00Z"
    private func gmtStartOfDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "GMT")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - 1. Current LOC counts tracked + untracked, classified per language

    func testCurrentLOCCountsTrackedAndUntrackedClassified() async throws {
        let dir = try Fixture.tempDir("loc")
        let repo = try emptyRepo(in: dir, name: "r")
        // a.swift: 3 code, 1 comment, 1 blank.
        try write("import Foundation\n// a comment\nlet x = 1\n\nlet y = 2\n", to: "a.swift", in: repo)
        // b.py: 2 code.
        try write("x = 1\ny = 2\n", to: "b.py", in: repo)
        try commit("c1", in: repo, date: day1)
        // c.js untracked but NOT gitignored: 1 code.
        try write("const z = 3;\n", to: "c.js", in: repo)

        var cache: [String: RepoFileCache] = [:]
        let result = await service.scan(projectPath: dir.path, scanDepth: 3,
                                        excludedRepos: [], cache: &cache)
        XCTAssertEqual(result.repos.count, 1)
        let s = result.aggregate
        // Swift 3+1+1, Python 2, JS 1 (untracked-not-ignored counted via --others).
        XCTAssertEqual(s.code, 3 + 2 + 1)
        XCTAssertEqual(s.comment, 1)
        XCTAssertEqual(s.blank, 1)
        XCTAssertEqual(s.totalFiles, 3)
        XCTAssertEqual(s.totalLines, 6 + 2 + 0)  // code+comment+blank across files

        let swift = try XCTUnwrap(s.byLanguage.first { $0.language == "Swift" })
        XCTAssertEqual(swift.code, 3); XCTAssertEqual(swift.comment, 1); XCTAssertEqual(swift.blank, 1)
        let py = try XCTUnwrap(s.byLanguage.first { $0.language == "Python" })
        XCTAssertEqual(py.code, 2)
        let js = try XCTUnwrap(s.byLanguage.first { $0.language == "TypeScript/JavaScript" })
        XCTAssertEqual(js.code, 1)
    }

    // MARK: - 2. Gitignored files excluded; unignored skip-list dirs are NOT

    func testGitignoredAndInfraDirFilesExcluded() async throws {
        let dir = try Fixture.tempDir("ignore")
        let repo = try emptyRepo(in: dir, name: "r")
        try write("let a = 1\n", to: "keep.swift", in: repo)
        try write("ignored/\n*.log\n", to: ".gitignore", in: repo)
        try write(String(repeating: "let big = 1\n", count: 1000), to: "ignored/big.swift", in: repo)
        try write("noise\n", to: "noise.log", in: repo)
        // An UNIGNORED build/x.swift is dropped too: `build` is an infrastructure dir
        // (generated output) — code stats never count it even when git tracks it. This
        // is what stops an untracked node_modules / .next tree from ballooning the count
        // when an umbrella repo forgot to gitignore a nested project's build output.
        try write("let b = 2\n", to: "build/x.swift", in: repo)
        // node_modules under an untracked path (NOT gitignored) is likewise excluded.
        try write("module.exports = 1\n", to: "node_modules/pkg/index.js", in: repo)
        try commit("c1", in: repo, date: day1)

        var cache: [String: RepoFileCache] = [:]
        let result = await service.scan(projectPath: dir.path, scanDepth: 3,
                                        excludedRepos: [], cache: &cache)
        let s = result.aggregate
        // Only keep.swift (1) survives: ignored/big.swift + noise.log gitignored;
        // build/ and node_modules/ dropped as infrastructure dirs.
        XCTAssertEqual(s.code, 1)
        XCTAssertEqual(s.totalFiles, 1)
        XCTAssertFalse(s.byLanguage.contains { $0.code >= 1000 }, "gitignored 1000-line file leaked in")
    }

    // MARK: - 3. Worktree files excluded (both .worktrees/ and a nested checkout)

    func testWorktreeFilesExcluded() async throws {
        let dir = try Fixture.tempDir("wt")
        let repo = try emptyRepo(in: dir, name: "r")
        try write("let m = 1\n", to: "m.swift", in: repo)
        try commit("c1", in: repo, date: day1)

        // A worktree under .worktrees/ (never discovered) ...
        let wtA = repo.appendingPathComponent(".worktrees").appendingPathComponent("feat-a")
        try FileManager.default.createDirectory(at: wtA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sh("git -C \(shellQuote(repo.path)) worktree add -q -b feat/a \(shellQuote(wtA.path)) main")
        // ... and a worktree nested directly under the PROJECT root (would be discovered
        // by the walk, but its .git is a FILE so discoverRepos skips it; the registered-
        // worktree filter is the belt-and-suspenders guard).
        let wtB = dir.appendingPathComponent("nested-wt")
        try sh("git -C \(shellQuote(repo.path)) worktree add -q -b feat/b \(shellQuote(wtB.path)) main")

        var cache: [String: RepoFileCache] = [:]
        let result = await service.scan(projectPath: dir.path, scanDepth: 3,
                                        excludedRepos: [], cache: &cache)
        // Only the main repo, counted once.
        XCTAssertEqual(result.repos.count, 1)
        XCTAssertEqual(norm(result.repos[0].repoPath), norm(repo.path))
        XCTAssertEqual(result.aggregate.code, 1)
        XCTAssertEqual(result.aggregate.totalFiles, 1)
    }

    // MARK: - 4. Per-day cumulative history; same-day commits collapse

    func testPerDayHistoryCumulative() async throws {
        let dir = try Fixture.tempDir("hist")
        let repo = try emptyRepo(in: dir, name: "r")
        // Day1: +10 lines.
        try write(String(repeating: "a\n", count: 10), to: "g.swift", in: repo)
        try write(String(repeating: "x = 1\n", count: 10), to: "f.py", in: repo)
        try commit("c1", in: repo, date: day1)
        // Day2: +5 lines (append).
        try write(String(repeating: "x = 1\n", count: 15), to: "f.py", in: repo)
        try commit("c2", in: repo, date: day2)
        // Day3: -3 lines (remove).
        try write(String(repeating: "x = 1\n", count: 12), to: "f.py", in: repo)
        try commit("c3", in: repo, date: day3)
        // Second commit on Day3: collapses with the first Day3 point (+2).
        try write(String(repeating: "x = 1\n", count: 14), to: "f.py", in: repo)
        try commit("c3b", in: repo, date: "2025-01-03T18:00:00Z")

        let branch = await service.resolveBranch(repo: info(repo))
        let (history, _) = await service.history(repo: info(repo), branch: branch,
                                                 period: GitStatsService.defaultPeriod,
                                                 now: gmtStartOfDay(2025, 1, 4))
        XCTAssertEqual(history.count, 3, "3 distinct days")
        // g.swift 10 lines + f.py 10 lines = 20 on day1; +5 -> 25; -3 then +2 -> 24.
        XCTAssertEqual(history[0].date, gmtStartOfDay(2025, 1, 1))
        XCTAssertEqual(history[0].netLines, 20)
        XCTAssertEqual(history[1].date, gmtStartOfDay(2025, 1, 2))
        XCTAssertEqual(history[1].netLines, 25)
        XCTAssertEqual(history[2].date, gmtStartOfDay(2025, 1, 3))
        XCTAssertEqual(history[2].netLines, 24, "two same-day commits collapse to end-of-day cumulative")
        // Per-day added/removed: day1 +20 (g.swift 10 + f.py 10); day2 +5; day3 two commits
        // ACCUMULATE — first trims f.py 15->12 (-3), second grows 12->14 (+2).
        XCTAssertEqual(history[0].dayAdded, 20)
        XCTAssertEqual(history[0].dayRemoved, 0)
        XCTAssertEqual(history[1].dayAdded, 5)
        XCTAssertEqual(history[1].dayRemoved, 0)
        XCTAssertEqual(history[2].dayAdded, 2, "second same-day commit added 2")
        XCTAssertEqual(history[2].dayRemoved, 3, "first same-day commit removed 3")
    }

    // MARK: - 5. Period delta added/removed/net/filesChanged

    func testPeriodDeltaAddedRemovedNet() async throws {
        let dir = try Fixture.tempDir("delta")
        let repo = try emptyRepo(in: dir, name: "r")
        // 40 days before "now": +20 (out of a 30d window).
        try write(String(repeating: "x = 1\n", count: 20), to: "old.py", in: repo)
        try commit("old", in: repo, date: "2025-05-01T12:00:00Z")
        // 5 days before "now": +8, -3 on a different file (in window).
        try write(String(repeating: "y = 2\n", count: 8), to: "new.py", in: repo)
        try commit("new-add", in: repo, date: "2025-06-05T12:00:00Z")
        try write(String(repeating: "y = 2\n", count: 5), to: "new.py", in: repo)  // -3
        try commit("new-trim", in: repo, date: "2025-06-05T18:00:00Z")

        // now = 2025-06-10, period = 30d -> cutoff 2025-05-11; old.py (May 1) excluded.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "GMT")!
        let now = cal.date(from: DateComponents(year: 2025, month: 6, day: 10, hour: 12))!
        let branch = await service.resolveBranch(repo: info(repo))
        let (_, delta) = await service.history(repo: info(repo), branch: branch,
                                               period: 30 * 24 * 3600, now: now)
        XCTAssertEqual(delta.added, 8)
        XCTAssertEqual(delta.removed, 3)
        XCTAssertEqual(delta.net, 5)
        XCTAssertEqual(delta.filesChanged, 1, "only new.py touched in window")
    }

    // MARK: - 6. Binary files skipped, not counted

    func testBinaryFilesSkippedNotCounted() async throws {
        let dir = try Fixture.tempDir("bin")
        let repo = try emptyRepo(in: dir, name: "r")
        try write("let ok = 1\n", to: "ok.swift", in: repo)
        // A .swift file with a NUL byte: extension matches but isLikelyBinary is true.
        let binURL = repo.appendingPathComponent("blob.swift")
        try Data([0x6c, 0x65, 0x74, 0x00, 0x78]).write(to: binURL)  // "let\0x"
        try commit("c1", in: repo, date: day1)

        var cache: [String: RepoFileCache] = [:]
        let result = await service.scan(projectPath: dir.path, scanDepth: 3,
                                        excludedRepos: [], cache: &cache)
        XCTAssertGreaterThanOrEqual(result.aggregate.skippedBinary, 1)
        XCTAssertEqual(result.aggregate.code, 1, "only ok.swift classified")
        XCTAssertEqual(result.aggregate.totalFiles, 1)
    }

    // MARK: - 7. Multi-repo aggregate + breakdown

    func testMultiRepoAggregateAndBreakdown() async throws {
        let dir = try Fixture.tempDir("multi")
        let repoA = try emptyRepo(in: dir, name: "repoA")
        try write(String(repeating: "let a = 1\n", count: 4), to: "a.swift", in: repoA)
        try commit("a", in: repoA, date: day1)
        let repoB = try emptyRepo(in: dir, name: "repoB")
        try write(String(repeating: "x = 1\n", count: 7), to: "b.py", in: repoB)
        try commit("b", in: repoB, date: day2)

        var cache: [String: RepoFileCache] = [:]
        let result = await service.scan(projectPath: dir.path, scanDepth: 3,
                                        excludedRepos: [], now: gmtStartOfDay(2025, 1, 4),
                                        cache: &cache)
        XCTAssertEqual(result.repos.count, 2)
        // Sorted by path: repoA before repoB.
        XCTAssertEqual(result.repos[0].repoName, "repoA")
        XCTAssertEqual(result.repos[1].repoName, "repoB")
        XCTAssertEqual(result.aggregate.code, 4 + 7)
        XCTAssertEqual(result.aggregate.totalLines, 4 + 7)
        // History summed with carry-forward: day1 has only A (4); day2 has A(4)+B(7)=11.
        XCTAssertEqual(result.aggregateHistory.count, 2)
        XCTAssertEqual(result.aggregateHistory[0].totalLines, 4)
        XCTAssertEqual(result.aggregateHistory[1].totalLines, 11)
        // Per-day added is POINT-IN-DAY (not carry-forward): day1 only A committed (+4),
        // day2 only B committed (+7). A contributes 0 to day2's per-day added.
        XCTAssertEqual(result.aggregateHistory[0].dayAdded, 4)
        XCTAssertEqual(result.aggregateHistory[0].dayRemoved, 0)
        XCTAssertEqual(result.aggregateHistory[1].dayAdded, 7)
        XCTAssertEqual(result.aggregateHistory[1].dayRemoved, 0)
    }

    // MARK: - 8. Cache reuse on no-change; invalidation on edit / HEAD change

    func testCacheReuseAndInvalidation() async throws {
        let dir = try Fixture.tempDir("cache")
        let repo = try emptyRepo(in: dir, name: "r")
        try write(String(repeating: "let a = 1\n", count: 3), to: "a.swift", in: repo)
        try commit("c1", in: repo, date: day1)

        // Pin `now` so the two no-change runs produce byte-identical CodeStats
        // (the production default Date() would differ sub-second in scannedAt).
        let fixedNow = gmtStartOfDay(2025, 6, 1)
        var cache: [String: RepoFileCache] = [:]
        let first = await service.scan(projectPath: dir.path, scanDepth: 3,
                                       excludedRepos: [], now: fixedNow, cache: &cache)
        XCTAssertEqual(first.aggregate.code, 3)
        XCTAssertFalse(cache.isEmpty)
        let head1 = try XCTUnwrap(cache.values.first?.head)
        XCTAssertFalse(head1.isEmpty)

        // Second run, no change: same totals, cache survives.
        let second = await service.scan(projectPath: dir.path, scanDepth: 3,
                                        excludedRepos: [], now: fixedNow, cache: &cache)
        XCTAssertEqual(second.aggregate, first.aggregate)

        // Modify the file (new mtime+size): line count reflects it (per-file gate).
        try write(String(repeating: "let a = 1\n", count: 6), to: "a.swift", in: repo)
        let third = await service.scan(projectPath: dir.path, scanDepth: 3,
                                       excludedRepos: [], now: fixedNow, cache: &cache)
        XCTAssertEqual(third.aggregate.code, 6)

        // A new commit changes HEAD -> whole cache invalidated, still correct.
        try commit("c2", in: repo, date: day2)
        let fourth = await service.scan(projectPath: dir.path, scanDepth: 3,
                                        excludedRepos: [], now: fixedNow, cache: &cache)
        XCTAssertEqual(fourth.aggregate.code, 6)
        let head2 = try XCTUnwrap(cache.values.first?.head)
        XCTAssertNotEqual(head1, head2, "HEAD advanced after the new commit")
    }

    // MARK: - 9. Empty / non-git dirs degrade gracefully

    func testEmptyAndNonGitDirsDegradeGracefully() async throws {
        let dir = try Fixture.tempDir("empty")
        // A plain directory with a file, no .git anywhere.
        try write("let x = 1\n", to: "loose.swift", in: dir)
        var cache: [String: RepoFileCache] = [:]
        let result = await service.scan(projectPath: dir.path, scanDepth: 3,
                                        excludedRepos: [], cache: &cache)
        XCTAssertTrue(result.repos.isEmpty)
        XCTAssertEqual(result.aggregate.totalLines, 0)
        XCTAssertEqual(result.aggregate.code, 0)
        XCTAssertTrue(result.aggregateHistory.isEmpty)
        XCTAssertEqual(result.aggregateDelta, .zero)
    }

    // MARK: - 10. Path-level exclusion (excludedFolders) removes matching files

    func testExcludedFoldersRemoveFilesFromCountAndList() async throws {
        let dir = try Fixture.tempDir("excluded")
        // The repo lives at <project>/r, so its files are project-relative under "r/".
        let repo = try emptyRepo(in: dir, name: "r")
        try write("let a = 1\n", to: "src/keep.swift", in: repo)
        try write("let b = 2\n", to: "gen/skip.swift", in: repo)
        try write("let c = 3\n", to: "data/nested/also.swift", in: repo)
        try commit("c1", in: repo, date: day1)

        var cache: [String: RepoFileCache] = [:]
        let result = await service.scan(projectPath: dir.path, scanDepth: 3,
                                        excludedRepos: [], excludedFolders: ["r/gen", "r/data"],
                                        cache: &cache)
        let s = result.aggregate
        XCTAssertEqual(s.code, 1, "only r/src/keep.swift counted; r/gen and r/data excluded")
        XCTAssertEqual(s.totalFiles, 1)
        // The excluded files are STILL emitted (so the settings tree can re-include
        // them) but flagged `isExcluded`; only the kept file counts toward totals.
        XCTAssertEqual(result.files.map(\.path).sorted(),
                       ["r/data/nested/also.swift", "r/gen/skip.swift", "r/src/keep.swift"])
        XCTAssertEqual(Set(result.files.filter { $0.isExcluded }.map(\.path)),
                       ["r/gen/skip.swift", "r/data/nested/also.swift"])
        let kept = try XCTUnwrap(result.files.first { $0.path == "r/src/keep.swift" })
        XCTAssertFalse(kept.isExcluded)
        // Per-file lines of the NON-excluded files sum to the aggregate total.
        let keptLines = result.files.filter { !$0.isExcluded }.reduce(0) { $0 + $1.lines }
        XCTAssertEqual(keptLines, s.code + s.comment + s.blank)
    }

    // MARK: - 11. .ignorestats matching removes files (reuses the gitignore parser)

    func testIgnorestatsFilesExcluded() async throws {
        let dir = try Fixture.tempDir("ignorestats")
        let repo = try emptyRepo(in: dir, name: "r")
        try write("let a = 1\n", to: "keep.swift", in: repo)
        try write("let b = 2\n", to: "skip.swift", in: repo)
        // A nested .ignorestats applies only within its directory subtree.
        try write("let c = 3\n", to: "sub/drop.swift", in: repo)
        try write("let d = 4\n", to: "sub/stay.swift", in: repo)
        try write("skip.swift\n", to: ".ignorestats", in: repo)
        try write("drop.swift\n", to: "sub/.ignorestats", in: repo)
        try commit("c1", in: repo, date: day1)

        var cache: [String: RepoFileCache] = [:]
        let result = await service.scan(projectPath: dir.path, scanDepth: 3,
                                        excludedRepos: [], excludedFolders: [],
                                        cache: &cache)
        let s = result.aggregate
        XCTAssertEqual(s.code, 2, "keep.swift + sub/stay.swift survive; skip.swift & sub/drop.swift ignored")
        // Output paths are project-relative (repo "r" under the project root -> "r/" prefix).
        XCTAssertEqual(Set(result.files.map(\.path)), ["r/keep.swift", "r/sub/stay.swift"])
    }

    // MARK: - 12. Per-file list present and SUMS to the aggregate totals

    func testPerFileListMatchesAggregate() async throws {
        let dir = try Fixture.tempDir("files")
        let repo = try emptyRepo(in: dir, name: "r")
        // a.swift: 3 code, 1 comment, 1 blank = 5 lines.
        try write("import Foundation\n// c\nlet x = 1\n\nlet y = 2\n", to: "a.swift", in: repo)
        // b.py: 2 code = 2 lines.
        try write("x = 1\ny = 2\n", to: "b.py", in: repo)
        // doc.md: data/prose.
        try write("# Title\n\ntext\n", to: "doc.md", in: repo)
        try commit("c1", in: repo, date: day1)

        var cache: [String: RepoFileCache] = [:]
        let result = await service.scan(projectPath: dir.path, scanDepth: 3,
                                        excludedRepos: [], excludedFolders: [],
                                        cache: &cache)
        XCTAssertEqual(result.files.count, result.aggregate.totalFiles, "one file entry per counted file")
        let sumLines = result.files.reduce(0) { $0 + $1.lines }
        XCTAssertEqual(sumLines, result.aggregate.code + result.aggregate.comment + result.aggregate.blank,
                       "per-file lines sum to the aggregate code+comment+blank total")
        // The data/prose flag is carried through for the markdown file (paths are
        // project-relative, so under the repo "r" they carry an "r/" prefix).
        let md = try XCTUnwrap(result.files.first { $0.path == "r/doc.md" })
        XCTAssertTrue(md.isDataProse)
        let swift = try XCTUnwrap(result.files.first { $0.path == "r/a.swift" })
        XCTAssertFalse(swift.isDataProse)
        XCTAssertEqual(swift.lines, 5)
    }

    // MARK: - 13. Project-relative paths correct for a NESTED repo

    func testProjectRelativePathsCorrectForNestedRepos() async throws {
        let dir = try Fixture.tempDir("nested")
        // Root-level repo: its files have NO prefix.
        let repo1 = try emptyRepo(in: dir, name: "r1")
        try write("let a = 1\n", to: "a.swift", in: repo1)
        try commit("c1", in: repo1, date: day1)
        // A repo nested under <project>/nested/r2: its files are prefixed "nested/r2/".
        let subdir = dir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let repo2 = try emptyRepo(in: subdir, name: "r2")
        try write("let b = 2\n", to: "deep/b.swift", in: repo2)
        try commit("c2", in: repo2, date: day1)

        var cache: [String: RepoFileCache] = [:]
        let result = await service.scan(projectPath: dir.path, scanDepth: 3,
                                        excludedRepos: [], excludedFolders: [],
                                        cache: &cache)
        XCTAssertGreaterThanOrEqual(result.files.count, 2)
        // repo1 file (the root repo "r1" is itself a child of the project root).
        XCTAssertTrue(result.files.contains { $0.path == "r1/a.swift" },
                      "root-level repo's file mapped under its dir relative to the project")
        // repo2 file carries the full nested prefix.
        XCTAssertTrue(result.files.contains { $0.path == "nested/r2/deep/b.swift" },
                      "nested repo's file has the correct project-relative prefix")
        // Excluding the nested repo's project-relative dir drops its file from the
        // COUNT but still emits it (flagged) so the tree can re-include it.
        var cache2: [String: RepoFileCache] = [:]
        let excluded = await service.scan(projectPath: dir.path, scanDepth: 3,
                                          excludedRepos: [], excludedFolders: ["nested"],
                                          cache: &cache2)
        XCTAssertEqual(excluded.aggregate.code, 1, "only r1/a.swift counts; nested/ excluded")
        let nestedFile = try XCTUnwrap(excluded.files.first { $0.path == "nested/r2/deep/b.swift" })
        XCTAssertTrue(nestedFile.isExcluded, "the excluded folder's file is present but flagged")
        let rootFile = try XCTUnwrap(excluded.files.first { $0.path == "r1/a.swift" })
        XCTAssertFalse(rootFile.isExcluded)
    }

    // MARK: - 14. projectRelativePrefix pure helper

    func testProjectRelativePrefixComputation() {
        XCTAssertEqual(GitStatsService.projectRelativePrefix(
            repoPath: "/p/proj/nested/r2", projectPath: "/p/proj"), "nested/r2")
        XCTAssertEqual(GitStatsService.projectRelativePrefix(
            repoPath: "/p/proj", projectPath: "/p/proj"), "", "repo IS the project root -> empty prefix")
        XCTAssertEqual(GitStatsService.projectRelativePrefix(
            repoPath: "/elsewhere/x", projectPath: "/p/proj"), "", "repo outside project -> empty fallback")
    }

    // MARK: - Pure-helper unit tests (no git)

    func testParseLsFilesZSplitsOnNUL() {
        let raw = "a.swift\u{0}dir/b.py\u{0}c with space.js\u{0}"
        XCTAssertEqual(GitStatsService.parseLsFilesZ(raw), ["a.swift", "dir/b.py", "c with space.js"])
    }

    func testParseLogAndBucketHistory() {
        // Two commits (newest-first), STX-separated header, numstat lines incl. a binary.
        let log = """
        \u{01}sha2\u{02}1735819200
        5\t0\tf.py
        -\t-\timg.png
        \u{01}sha1\u{02}1735732800
        10\t0\tf.py
        """
        let commits = GitStatsService.parseLog(log)
        XCTAssertEqual(commits.count, 2)
        // Binary file skipped: sha2 added=5 (not counting img.png).
        XCTAssertEqual(commits[0].added, 5)
        XCTAssertEqual(commits[0].paths, ["f.py"])  // img.png excluded
        let history = GitStatsService.bucketHistory(commits: commits)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].netLines, 10)       // oldest day
        XCTAssertEqual(history[1].netLines, 15)       // cumulative
        // Per-day added/removed are point-in-day (not cumulative): oldest +10, next +5.
        XCTAssertEqual(history[0].dayAdded, 10)
        XCTAssertEqual(history[0].dayRemoved, 0)
        XCTAssertEqual(history[1].dayAdded, 5)
        XCTAssertEqual(history[1].dayRemoved, 0)
    }

    /// Regression: `git log` emits reverse-GRAPH order, where a child commit can carry
    /// an EARLIER timestamp than its parent (rebase/cherry-pick/amend/clock skew). The
    /// input here is in that graph order — newest-first by topology is [child(Jan1, +5),
    /// parent(Jan5, +10)] — but Jan1 is chronologically BEFORE Jan5. `bucketHistory` must
    /// sort by date, so the result is date-ASC with the correct end-of-day cumulative:
    /// Jan1 -> 5 (child first chronologically), Jan5 -> 15. A naive `.reversed()` would
    /// have produced [(Jan5, 10), (Jan1, 15)] — out of order AND wrong per-day values.
    func testBucketHistoryHandlesNonChronologicalGitLogOrder() {
        let jan1: TimeInterval = 1735732800  // 2025-01-01T12:00:00Z
        let jan5: TimeInterval = 1736078400  // 2025-01-05T12:00:00Z
        // Graph order (as `git log` emits): child first, then parent.
        let log = """
        \u{01}child\u{02}\(Int(jan1))
        5\t0\tf.swift
        \u{01}parent\u{02}\(Int(jan5))
        10\t0\tf.swift
        """
        let commits = GitStatsService.parseLog(log)
        XCTAssertEqual(commits.count, 2)
        let history = GitStatsService.bucketHistory(commits: commits)
        XCTAssertEqual(history.count, 2)
        // Date-sorted oldest-first (Jan 1 before Jan 5), correct cumulative per day.
        XCTAssertEqual(history[0].date, gmtStartOfDay(2025, 1, 1))
        XCTAssertEqual(history[0].netLines, 5, "child committed first chronologically")
        XCTAssertEqual(history[1].date, gmtStartOfDay(2025, 1, 5))
        XCTAssertEqual(history[1].netLines, 15, "end-of-day cumulative after both commits")
        XCTAssertTrue(history[0].date < history[1].date, "history must be date-sorted oldest-first")
        // Per-day added follows the same chronological re-sort: Jan1 +5, Jan5 +10.
        XCTAssertEqual(history[0].dayAdded, 5)
        XCTAssertEqual(history[1].dayAdded, 10)
    }

    /// End-to-end variant of the above against a REAL repo whose child commit has an
    /// earlier committer date than its parent (simulating a rebase/amend). Asserts the
    /// per-repo history that `history(...)` returns is date-sorted with correct
    /// cumulatives despite git's graph-ordered log.
    func testHistoryDateSortedWhenCommitDatesNonMonotonic() async throws {
        let dir = try Fixture.tempDir("nonmono")
        let repo = try emptyRepo(in: dir, name: "r")
        // Parent commit dated LATER (Jan 5): +10 lines.
        try write(String(repeating: "a\n", count: 10), to: "f.swift", in: repo)
        try commit("parent", in: repo, date: "2025-01-05T12:00:00Z")
        // Child commit (descends from parent) dated EARLIER (Jan 1): +5 lines.
        try write(String(repeating: "a\n", count: 15), to: "f.swift", in: repo)
        try commit("child", in: repo, date: "2025-01-01T12:00:00Z")

        let branch = await service.resolveBranch(repo: info(repo))
        let (history, _) = await service.history(repo: info(repo), branch: branch,
                                                 period: GitStatsService.defaultPeriod,
                                                 now: gmtStartOfDay(2025, 1, 6))
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].date, gmtStartOfDay(2025, 1, 1))
        XCTAssertEqual(history[0].netLines, 5, "earlier-dated child accumulates first")
        XCTAssertEqual(history[1].date, gmtStartOfDay(2025, 1, 5))
        XCTAssertEqual(history[1].netLines, 15)
        XCTAssertTrue(history[0].date < history[1].date, "date-sorted oldest-first")
    }

    // MARK: - Branch override: history/delta follow the chosen branch

    /// A `branchOverrides[repo.path]` naming a real branch makes the scan use THAT
    /// branch's commit history (and report it as the effective `defaultBranch`), while
    /// the default scan uses the auto-detected branch. The two branches carry distinct
    /// commit histories, so the per-repo cumulative net-lines differ. (Current LOC comes
    /// from the working tree and is branch-independent, so we assert on history, which is
    /// the only branch-dependent output.)
    func testOverrideBranchChangesHistory() async throws {
        let dir = try Fixture.tempDir("override")
        let repo = try emptyRepo(in: dir, name: "r")
        // main: +10 lines on day1.
        try write(String(repeating: "a\n", count: 10), to: "f.swift", in: repo)
        try commit("c1", in: repo, date: day1)
        // other branches off main and adds another +10 (so its history ends at 20), then
        // we check BACK OUT to main so the checked-out (HEAD) branch — which resolveBranch
        // now prefers — is main. The override still selects `other` explicitly.
        try sh("git -C \(shellQuote(repo.path)) checkout -qb other")
        try write(String(repeating: "a\n", count: 20), to: "f.swift", in: repo)
        try commit("c2", in: repo, date: day2)
        try sh("git -C \(shellQuote(repo.path)) checkout -q main")

        let now = gmtStartOfDay(2025, 1, 4)

        // Default scan resolves to the checked-out main: history ends at the day1 commit.
        var cacheMain: [String: RepoFileCache] = [:]
        let statsMain = await service.scan(projectPath: dir.path, scanDepth: 3,
                                           excludedRepos: [], now: now, cache: &cacheMain)
        XCTAssertEqual(statsMain.repos.first?.defaultBranch, "main")
        XCTAssertEqual(statsMain.repos.first?.history.last?.netLines, 10,
                       "default (main) history tops out at 10")

        // Override to `other`: history now includes c2, topping out at 20, and the
        // effective branch reported back is `other`.
        var cacheOther: [String: RepoFileCache] = [:]
        let statsOther = await service.scan(projectPath: dir.path, scanDepth: 3,
                                            excludedRepos: [],
                                            branchOverrides: [norm(repo.path): "other"],
                                            now: now, cache: &cacheOther)
        XCTAssertEqual(statsOther.repos.first?.defaultBranch, "other")
        XCTAssertEqual(statsOther.repos.first?.history.last?.netLines, 20,
                       "override (other) history tops out at 20")
    }

    // MARK: - 15. parseLog classifies numstat by language group (code vs data/prose)

    func testParseLogClassifiesLanguages() {
        // A commit touching a .swift (code), a .txt (UNRECOGNIZED extension → skipped, like the
        // working-tree scan), and a .md (data/prose). A binary line is skipped entirely.
        let log = """
        \u{01}sha1\u{02}1735732800
        10\t2\ta.swift
        7\t0\tnotes.txt
        4\t1\tREADME.md
        -\t-\timg.png
        """
        let commits = GitStatsService.parseLog(log)
        XCTAssertEqual(commits.count, 1)
        let c = commits[0]
        // The unrecognized .txt is dropped entirely, so totals exclude it: added 10+4=14,
        // removed 2+1=3 (binary img.png also skipped, .txt skipped).
        XCTAssertEqual(c.added, 14)
        XCTAssertEqual(c.removed, 3)
        // Code = swift only (.txt no longer counts): added 10, removed 2.
        XCTAssertEqual(c.codeAdded, 10)
        XCTAssertEqual(c.codeRemoved, 2)
        // Data = markdown only: added 4, removed 1.
        XCTAssertEqual(c.dataAdded, 4)
        XCTAssertEqual(c.dataRemoved, 1)
        // The skipped file isn't recorded as a touched path either.
        XCTAssertFalse(c.paths.contains("notes.txt"))
        // Invariant: code + data == total (both recognized-only now).
        XCTAssertEqual(c.codeAdded + c.dataAdded, c.added)
        XCTAssertEqual(c.codeRemoved + c.dataRemoved, c.removed)
    }

    func testBucketHistoryPreservesClassification() {
        // Two days. Day1: swift +10/-0, md +5/-0. Day2: json +0/-8 (data removal), go +3/-1.
        let day1: TimeInterval = 1735732800  // 2025-01-01T12:00:00Z
        let day2: TimeInterval = 1735819200  // 2025-01-02T12:00:00Z
        let log = """
        \u{01}d2\u{02}\(Int(day2))
        0\t8\tconfig.json
        3\t1\tmain.go
        \u{01}d1\u{02}\(Int(day1))
        10\t0\ta.swift
        5\t0\tdoc.md
        """
        let history = GitStatsService.bucketHistory(commits: GitStatsService.parseLog(log))
        XCTAssertEqual(history.count, 2)
        // Day1 (oldest first): code = swift 10 added; data = md 5 added.
        XCTAssertEqual(history[0].date, gmtStartOfDay(2025, 1, 1))
        XCTAssertEqual(history[0].codeAdded, 10)
        XCTAssertEqual(history[0].codeRemoved, 0)
        XCTAssertEqual(history[0].dataAdded, 5)
        XCTAssertEqual(history[0].dataRemoved, 0)
        // Day2: code = go 3 added / 1 removed; data = json 0 added / 8 removed.
        XCTAssertEqual(history[1].date, gmtStartOfDay(2025, 1, 2))
        XCTAssertEqual(history[1].codeAdded, 3)
        XCTAssertEqual(history[1].codeRemoved, 1)
        XCTAssertEqual(history[1].dataAdded, 0)
        XCTAssertEqual(history[1].dataRemoved, 8)
        // Per-day classified split sums to the per-day totals on each day.
        for p in history {
            XCTAssertEqual(p.codeAdded + p.dataAdded, p.dayAdded)
            XCTAssertEqual(p.codeRemoved + p.dataRemoved, p.dayRemoved)
        }
    }

    // MARK: - 16. languageSplitDelta over a window

    func testLanguageSplitDeltaWindow() {
        let inWindow: TimeInterval = 1735819200   // 2025-01-02T12:00:00Z
        let outOfWindow: TimeInterval = 1700000000 // ~2023, well before the cutoff
        let log = """
        \u{01}new\u{02}\(Int(inWindow))
        12\t3\tsrc.swift
        4\t1\tdata.yaml
        \u{01}old\u{02}\(Int(outOfWindow))
        99\t0\tancient.swift
        """
        let commits = GitStatsService.parseLog(log)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "GMT")!
        let now = cal.date(from: DateComponents(year: 2025, month: 1, day: 5, hour: 12))!
        let split = GitStatsService.languageSplitDelta(commits: commits, period: 30 * 24 * 3600, now: now)
        // Only the in-window commit counts: code = swift 12/-3, data = yaml 4/-1.
        XCTAssertEqual(split.codeAdded, 12)
        XCTAssertEqual(split.codeRemoved, 3)
        XCTAssertEqual(split.dataAdded, 4)
        XCTAssertEqual(split.dataRemoved, 1)
    }

    // MARK: - 17. Net-negative window (added < removed) is reported correctly

    func testNetNegativeWindowReported() async throws {
        let dir = try Fixture.tempDir("net-neg")
        let repo = try emptyRepo(in: dir, name: "r")
        // Seed 150 lines well inside the window.
        try write(String(repeating: "x = 1\n", count: 150), to: "f.py", in: repo)
        try commit("seed", in: repo, date: "2025-06-02T12:00:00Z")
        // Then trim down to 50 and grow back to 100: that day adds 50, removes 100 → net −50.
        try write(String(repeating: "x = 1\n", count: 50), to: "f.py", in: repo)  // -100
        try commit("trim", in: repo, date: "2025-06-03T12:00:00Z")
        try write(String(repeating: "x = 1\n", count: 100), to: "f.py", in: repo) // +50
        try commit("grow", in: repo, date: "2025-06-03T18:00:00Z")

        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "GMT")!
        let now = cal.date(from: DateComponents(year: 2025, month: 6, day: 4, hour: 12))!
        let branch = await service.resolveBranch(repo: info(repo))
        let (_, delta) = await service.history(repo: info(repo), branch: branch,
                                               period: 30 * 24 * 3600, now: now)
        // Window adds 150 (seed) + 50 (grow) = 200; removes 100 (trim). Net positive overall.
        // The day3-only window is the interesting net-negative slice:
        XCTAssertEqual(delta.added, 200)
        XCTAssertEqual(delta.removed, 100)
        // The trim/grow DAY alone is net-negative: +50 / -100.
        let (history, _) = await service.history(repo: info(repo), branch: branch,
                                                 period: 30 * 24 * 3600, now: now)
        let day3 = try XCTUnwrap(history.first { $0.date == gmtStartOfDay(2025, 6, 3) })
        XCTAssertEqual(day3.dayAdded, 50)
        XCTAssertEqual(day3.dayRemoved, 100)
        XCTAssertLessThan(day3.dayAdded - day3.dayRemoved, 0, "the trim/grow day is net-negative")
    }

    // MARK: - 18. Umbrella ancestor exclusion (parent repo + 2 nested children)

    func testUmbrellaRepoAncestorExcluded() async throws {
        let dir = try Fixture.tempDir("umbrella")
        // An umbrella repo (its OWN .git) that CONTAINS two real product repos.
        let umbrella = try emptyRepo(in: dir, name: "monorepo")
        try write("# umbrella\n", to: "README.md", in: umbrella)
        try commit("umbrella", in: umbrella, date: day1)
        // Two nested children, each a real git repo.
        let child1 = try emptyRepo(in: umbrella, name: "client")
        try write("let a = 1\n", to: "a.swift", in: child1)
        try commit("c1", in: child1, date: day1)
        let child2 = try emptyRepo(in: umbrella, name: "server")
        try write("let b = 2\n", to: "b.swift", in: child2)
        try commit("c2", in: child2, date: day1)

        let repos = await service.reposToScan(projectPath: dir.path, scanDepth: 4, excluded: [])
        let names = Set(repos.map(\.dirName))
        XCTAssertFalse(names.contains("monorepo"), "the umbrella parent is dropped")
        XCTAssertEqual(names, ["client", "server"], "only the two nested children remain")
    }

    // MARK: - 19. resolveBranch prefers the checked-out (HEAD) branch over master

    func testResolveBranchReturnsCurrentCheckedOutBranch() async throws {
        let dir = try Fixture.tempDir("head-branch")
        // master EXISTS (origin/HEAD-style default), but HEAD is on a feature branch.
        let repo = try emptyRepo(in: dir, name: "r", branch: "master")
        try write("let a = 1\n", to: "a.swift", in: repo)
        try commit("c1", in: repo, date: day1)
        try sh("git -C \(shellQuote(repo.path)) checkout -qb refactor/bloc-to-vm-migration")
        try write("let b = 2\n", to: "b.swift", in: repo)
        try commit("c2", in: repo, date: day2)

        let branch = await service.resolveBranch(repo: info(repo))
        XCTAssertEqual(branch, "refactor/bloc-to-vm-migration",
                       "resolveBranch returns the checked-out HEAD branch, not master")
    }

    // MARK: - 20. dropUmbrellaAncestors pure helper

    func testDropUmbrellaAncestorsPure() {
        let repos = [
            RepoInfo(path: "/p/monorepo", dirName: "monorepo"),
            RepoInfo(path: "/p/monorepo/client", dirName: "client"),
            RepoInfo(path: "/p/monorepo/server", dirName: "server"),
            RepoInfo(path: "/p/standalone", dirName: "standalone"),
        ]
        let kept = GitStatsService.dropUmbrellaAncestors(repos).map(\.dirName)
        // The umbrella parent is dropped; the two children + the standalone remain.
        XCTAssertEqual(Set(kept), ["client", "server", "standalone"])
        // A sibling whose name is a prefix of another (NOT a path ancestor) is kept.
        let siblings = [
            RepoInfo(path: "/p/app", dirName: "app"),
            RepoInfo(path: "/p/app-extra", dirName: "app-extra"),
        ]
        XCTAssertEqual(GitStatsService.dropUmbrellaAncestors(siblings).count, 2,
                       "a name prefix that is not a path-segment ancestor is not dropped")
    }

    /// An override that does NOT name a real local branch is ignored: the scan silently
    /// falls back to the auto-detected default branch.
    func testInvalidOverrideBranchFallsBackToDefault() async throws {
        let dir = try Fixture.tempDir("invalid-override")
        let repo = try emptyRepo(in: dir, name: "r")
        try write("let x = 1\n", to: "f.swift", in: repo)
        try commit("c1", in: repo, date: day1)

        var cache: [String: RepoFileCache] = [:]
        let stats = await service.scan(projectPath: dir.path, scanDepth: 3,
                                       excludedRepos: [],
                                       branchOverrides: [norm(repo.path): "nonexistent"],
                                       now: gmtStartOfDay(2025, 1, 4), cache: &cache)
        XCTAssertEqual(stats.repos.first?.defaultBranch, "main",
                       "invalid override falls back to the detected default")
        XCTAssertEqual(stats.repos.first?.stats.code, 1)
    }

    // MARK: - 21. Worktree branch override: LOC reflects the WORKTREE's working tree

    /// When the override branch IS checked out in a linked worktree, `currentLOC`
    /// must scan THAT worktree's working tree — so its unique file (C.swift) appears
    /// in the stats, unlike the main-checkout scan which only sees A.swift + B.swift.
    func testWorktreeBranchOverrideReflectsWorktreeFiles() async throws {
        let dir = try Fixture.tempDir("wt-override")
        let repo = try emptyRepo(in: dir, name: "r")
        // main: A.swift + B.swift
        try write("let a = 1\n", to: "A.swift", in: repo)
        try write("let b = 2\n", to: "B.swift", in: repo)
        try commit("main-commit", in: repo, date: day1)

        // Create branch `feature` off main, add C.swift committed there
        try sh("git -C \(shellQuote(repo.path)) checkout -qb feature")
        try write("let c = 3\nlet d = 4\n", to: "C.swift", in: repo)
        try commit("feature-commit", in: repo, date: day2)
        // Return main checkout to `main`
        try sh("git -C \(shellQuote(repo.path)) checkout -q main")

        // Add a linked worktree for `feature` at a separate temp path
        let wtDir = try Fixture.tempDir("wt-feat")
        let featureWt = wtDir.appendingPathComponent("r-feature")
        try sh("git -C \(shellQuote(repo.path)) worktree add \(shellQuote(featureWt.path)) feature")

        let now = gmtStartOfDay(2025, 1, 4)
        var cache: [String: RepoFileCache] = [:]
        let stats = await service.scan(projectPath: dir.path, scanDepth: 3,
                                       excludedRepos: [],
                                       branchOverrides: [norm(repo.path): "feature"],
                                       now: now, cache: &cache)
        let repo0 = try XCTUnwrap(stats.repos.first)
        // C.swift must appear (it only exists in the feature worktree, not in main checkout)
        XCTAssertTrue(stats.files.contains { $0.path.hasSuffix("C.swift") },
                      "feature worktree's C.swift must appear in the stats")
        // LOC must include C.swift's 2 lines (plus A.swift 1 and B.swift 1 = 4 total)
        XCTAssertEqual(repo0.stats.code, 4,
                       "feature worktree LOC = A(1) + B(1) + C(2) = 4")
    }

    // MARK: - 22. Branch switch changes LOC numbers (cache-bust)

    /// Scanning main then overriding to feature must produce DIFFERENT stats, proving
    /// the per-repo cache doesn't serve stale main data when the branch changes.
    func testBranchSwitchBustsCache() async throws {
        let dir = try Fixture.tempDir("branch-cache-bust")
        let repo = try emptyRepo(in: dir, name: "r")
        // main: 3 lines
        try write("let a = 1\nlet b = 2\nlet c = 3\n", to: "main.swift", in: repo)
        try commit("main-commit", in: repo, date: day1)

        // feature: adds extra.swift with 5 lines
        try sh("git -C \(shellQuote(repo.path)) checkout -qb feature")
        try write(String(repeating: "let x = 1\n", count: 5), to: "extra.swift", in: repo)
        try commit("feature-commit", in: repo, date: day2)
        try sh("git -C \(shellQuote(repo.path)) checkout -q main")

        // Add linked worktree for feature
        let wtDir = try Fixture.tempDir("wt-feat2")
        let featureWt = wtDir.appendingPathComponent("r-feature2")
        try sh("git -C \(shellQuote(repo.path)) worktree add \(shellQuote(featureWt.path)) feature")

        let now = gmtStartOfDay(2025, 1, 4)

        // First scan: no override → main (3 lines)
        var cache: [String: RepoFileCache] = [:]
        let mainStats = await service.scan(projectPath: dir.path, scanDepth: 3,
                                           excludedRepos: [], now: now, cache: &cache)
        let mainCode = mainStats.aggregate.code
        XCTAssertEqual(mainCode, 3, "main scan: 3 lines in main.swift")

        // Second scan: override to feature — must differ from the cached main result
        var cache2 = cache  // start from the same cache
        let featureStats = await service.scan(projectPath: dir.path, scanDepth: 3,
                                              excludedRepos: [],
                                              branchOverrides: [norm(repo.path): "feature"],
                                              now: now, cache: &cache2)
        let featureCode = featureStats.aggregate.code
        XCTAssertEqual(featureCode, 8,
                       "feature scan: main.swift(3) + extra.swift(5) = 8; cache must not serve stale main data")
        XCTAssertNotEqual(mainCode, featureCode, "branch switch must bust the cache and produce different LOC")
    }

    // MARK: - 23. No-worktree branch → committed tree

    /// When the override branch is NOT checked out in any worktree (it shares checkout
    /// space with the main branch), stats come from the branch's COMMITTED tree via
    /// git ls-tree, NOT from uncommitted junk in the main working dir.
    func testNoWorktreeBranchUsesCommittedTree() async throws {
        let dir = try Fixture.tempDir("committed-tree")
        let repo = try emptyRepo(in: dir, name: "r")
        // main: only main.swift
        try write("let a = 1\n", to: "main.swift", in: repo)
        try commit("main-commit", in: repo, date: day1)

        // solo branch: commits solo.swift (2 lines), then returns to main
        try sh("git -C \(shellQuote(repo.path)) checkout -qb solo")
        try write("let x = 1\nlet y = 2\n", to: "solo.swift", in: repo)
        try commit("solo-commit", in: repo, date: day2)
        try sh("git -C \(shellQuote(repo.path)) checkout -q main")

        // Place uncommitted junk in the main working tree — must NOT appear in solo stats
        try write("let junk = 99\nlet junk2 = 100\n", to: "junk.swift", in: repo)

        let now = gmtStartOfDay(2025, 1, 4)
        var cache: [String: RepoFileCache] = [:]
        let stats = await service.scan(projectPath: dir.path, scanDepth: 3,
                                       excludedRepos: [],
                                       branchOverrides: [norm(repo.path): "solo"],
                                       now: now, cache: &cache)

        // solo's committed tree: solo.swift (2 lines) + main.swift (1 line, inherited) = 3
        // junk.swift must NOT appear (it's only in the working tree, not in solo's committed tree)
        XCTAssertFalse(stats.files.contains { $0.path.hasSuffix("junk.swift") },
                       "uncommitted junk in main working dir must not appear in solo committed-tree stats")
        XCTAssertTrue(stats.files.contains { $0.path.hasSuffix("solo.swift") },
                      "solo.swift from the committed tree must appear")
        XCTAssertEqual(stats.aggregate.code, 3,
                       "solo committed tree: main.swift(1) + solo.swift(2) = 3")
    }

    // MARK: - 24a. cat-file --batch framing: multiple files, mixed sizes, no-trailing-newline, binary

    /// Tests the batch blob-fetch path with multiple files of different sizes and types.
    /// This locks the `git cat-file --batch` framing/parsing: size-delimited payloads,
    /// multiple objects in one stream, one file without a trailing newline, and one
    /// binary file (NUL byte) that must be skipped exactly as the working-tree path does.
    func testCommittedTreeBatchFetchMultipleFiles() async throws {
        let dir = try Fixture.tempDir("batch-multi")
        let repo = try emptyRepo(in: dir, name: "r")

        // File 1: large.swift — 10 code lines (has trailing newline).
        try write(Array(repeating: "let x = 1\n", count: 10).joined(), to: "large.swift", in: repo)

        // File 2: tiny.py — 1 code line, NO trailing newline (edge case for payload framing).
        // We write it without a trailing newline via Data so String.write won't add one.
        let tinyURL = repo.appendingPathComponent("tiny.py")
        try Data("x = 1".utf8).write(to: tinyURL)

        // File 3: notes.md — 3 lines of markdown prose (data/prose language).
        try write("# Title\n\nSome text.\n", to: "notes.md", in: repo)

        // File 4: binary.bin — contains a NUL byte; must be skipped (isLikelyBinary).
        let binaryURL = repo.appendingPathComponent("binary.bin")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x00, 0x0d, 0x0a]).write(to: binaryURL)
        // binary.bin has no known language → language(forPath:) returns nil → silently dropped.
        // For a more targeted binary test, we need a .swift file with a NUL byte:
        let binarySwiftURL = repo.appendingPathComponent("corrupt.swift")
        try Data("let x = \0nil\n".utf8).write(to: binarySwiftURL)

        try commit("batch-commit", in: repo, date: day1)

        // Create a feature branch, add one more file.
        try sh("git -C \(shellQuote(repo.path)) checkout -qb feature")
        try write("func foo() {}\nfunc bar() {}\nfunc baz() {}\n", to: "extra.swift", in: repo)
        try commit("feature-commit", in: repo, date: day2)
        try sh("git -C \(shellQuote(repo.path)) checkout -q main")

        // Now scan feature as a committed-tree (not checked out).
        let now = gmtStartOfDay(2025, 1, 4)
        var cache: [String: RepoFileCache] = [:]
        let stats = await service.scan(projectPath: dir.path, scanDepth: 3,
                                       excludedRepos: [],
                                       branchOverrides: [norm(repo.path): "feature"],
                                       now: now, cache: &cache)

        // Verify per-file presence.
        XCTAssertTrue(stats.files.contains { $0.path.hasSuffix("large.swift") },
                      "large.swift must appear in batch results")
        XCTAssertTrue(stats.files.contains { $0.path.hasSuffix("tiny.py") },
                      "tiny.py (no trailing newline) must appear in batch results")
        XCTAssertTrue(stats.files.contains { $0.path.hasSuffix("notes.md") },
                      "notes.md (prose) must appear in batch results")
        XCTAssertTrue(stats.files.contains { $0.path.hasSuffix("extra.swift") },
                      "extra.swift (from feature branch) must appear in batch results")
        // corrupt.swift has a NUL byte → skipped as binary; must NOT appear.
        XCTAssertFalse(stats.files.contains { $0.path.hasSuffix("corrupt.swift") },
                       "binary (NUL-containing) swift file must be skipped")

        // Verify line counts.
        // large.swift: 10 code lines (all `let x = 1`)
        let largeEntry = try XCTUnwrap(stats.files.first { $0.path.hasSuffix("large.swift") })
        XCTAssertEqual(largeEntry.lines, 10, "large.swift must have 10 classified lines")

        // tiny.py: 1 code line, no trailing newline
        let tinyEntry = try XCTUnwrap(stats.files.first { $0.path.hasSuffix("tiny.py") })
        XCTAssertEqual(tinyEntry.lines, 1, "tiny.py (no trailing newline) must have 1 line")

        // extra.swift: 3 code lines
        let extraEntry = try XCTUnwrap(stats.files.first { $0.path.hasSuffix("extra.swift") })
        XCTAssertEqual(extraEntry.lines, 3, "extra.swift must have 3 classified lines")

        // Total code lines: large.swift(10) + tiny.py(1) + extra.swift(3) + notes.md(2) = 16.
        // Markdown has no comment syntax, so all non-blank lines are classified as code:
        // "# Title" (code), "" (blank), "Some text." (code) → 2 code lines.
        XCTAssertEqual(stats.aggregate.code, 16,
                       "batch: large(10) + tiny(1) + extra(3) + notes.md(2 non-blank) = 16 code lines")
    }

    // MARK: - 24. Default (no override) behavior is unchanged

    /// No override → scan uses the main checkout's working tree, identical to pre-change.
    func testDefaultNoOverrideUnchanged() async throws {
        let dir = try Fixture.tempDir("default-no-override")
        let repo = try emptyRepo(in: dir, name: "r")
        try write("let a = 1\nlet b = 2\n", to: "a.swift", in: repo)
        try write("x = 1\ny = 2\nz = 3\n", to: "b.py", in: repo)
        try commit("c1", in: repo, date: day1)
        // An untracked file also counted by the working-tree scan
        try write("const z = 3;\n", to: "c.js", in: repo)

        let now = gmtStartOfDay(2025, 1, 4)
        var cache: [String: RepoFileCache] = [:]
        let stats = await service.scan(projectPath: dir.path, scanDepth: 3,
                                       excludedRepos: [], now: now, cache: &cache)

        // a.swift: 2 code; b.py: 3 code; c.js (untracked): 1 code; total = 6
        XCTAssertEqual(stats.aggregate.code, 6, "default scan includes tracked + untracked-not-ignored")
        XCTAssertEqual(stats.aggregate.totalFiles, 3)
        XCTAssertTrue(stats.files.contains { $0.path.hasSuffix("c.js") },
                      "untracked c.js must still appear with no override (default working-tree behavior)")
    }
}
