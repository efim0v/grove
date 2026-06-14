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
        try write(String(repeating: "a\n", count: 10), to: "f.txt", in: repo)  // .txt unclassified; numstat still counts
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
        // f.txt 10 lines + f.py 10 lines = 20 on day1; +5 -> 25; -3 then +2 -> 24.
        XCTAssertEqual(history[0].date, gmtStartOfDay(2025, 1, 1))
        XCTAssertEqual(history[0].netLines, 20)
        XCTAssertEqual(history[1].date, gmtStartOfDay(2025, 1, 2))
        XCTAssertEqual(history[1].netLines, 25)
        XCTAssertEqual(history[2].date, gmtStartOfDay(2025, 1, 3))
        XCTAssertEqual(history[2].netLines, 24, "two same-day commits collapse to end-of-day cumulative")
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
        5\t0\tf.txt
        \u{01}parent\u{02}\(Int(jan5))
        10\t0\tf.txt
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
    }

    /// End-to-end variant of the above against a REAL repo whose child commit has an
    /// earlier committer date than its parent (simulating a rebase/amend). Asserts the
    /// per-repo history that `history(...)` returns is date-sorted with correct
    /// cumulatives despite git's graph-ordered log.
    func testHistoryDateSortedWhenCommitDatesNonMonotonic() async throws {
        let dir = try Fixture.tempDir("nonmono")
        let repo = try emptyRepo(in: dir, name: "r")
        // Parent commit dated LATER (Jan 5): +10 lines.
        try write(String(repeating: "a\n", count: 10), to: "f.txt", in: repo)
        try commit("parent", in: repo, date: "2025-01-05T12:00:00Z")
        // Child commit (descends from parent) dated EARLIER (Jan 1): +5 lines.
        try write(String(repeating: "a\n", count: 15), to: "f.txt", in: repo)
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
}
