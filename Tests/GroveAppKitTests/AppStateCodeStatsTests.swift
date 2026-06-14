import XCTest
import GroveCore
@testable import GroveAppKit

@MainActor
final class AppStateCodeStatsTests: XCTestCase {
    private var root: URL!
    private var statsDir: URL!
    private var configURL: URL!
    private var projectDir: URL!
    private var project: ProjectConfig!

    // Layout built in setUp under <root>/project — a REAL git repo (the stats are now
    // GIT-derived: GitStatsService counts the repo's tracked+untracked-not-ignored file
    // set and reads history from `git log`):
    //   main.swift             3 code, 1 comment, 1 blank
    //   sub/deep.swift         1 code
    //   vendor/lib.swift       2 code   (excludable via a .gitignore entry)
    // All committed at a pinned date so the git-derived history is deterministic.
    private let commitDate = "2025-03-04T12:00:00Z"

    override func setUp() async throws {
        // Skip when git is unavailable (the stats path now shells out to git).
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["git", "--version"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try? probe.run(); probe.waitUntilExit()
        try XCTSkipUnless(probe.terminationStatus == 0, "git not available")

        root = try FixtureLite.tempDir("appstate-codestats")
        statsDir = root.appendingPathComponent("stats")
        projectDir = root.appendingPathComponent("project")
        let fm = FileManager.default
        try fm.createDirectory(at: projectDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: projectDir.appendingPathComponent("vendor"), withIntermediateDirectories: true)
        try "import Foundation\n// a comment\n\nlet x = 1\nprint(x)\n"
            .write(to: projectDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "let d = 1\n"
            .write(to: projectDir.appendingPathComponent("sub/deep.swift"), atomically: true, encoding: .utf8)
        try "let v = 1\nlet v2 = 2\n"
            .write(to: projectDir.appendingPathComponent("vendor/lib.swift"), atomically: true, encoding: .utf8)

        // Make it a git repo and commit everything at a pinned date.
        try FixtureLite.sh("git init -q -b main", cwd: projectDir)
        try FixtureLite.sh("git config user.email t@t && git config user.name t", cwd: projectDir)
        let env = "GIT_AUTHOR_DATE='\(commitDate)' GIT_COMMITTER_DATE='\(commitDate)'"
        try FixtureLite.sh("\(env) git add -A && \(env) git commit -qm c1", cwd: projectDir)

        project = ProjectConfig(name: "project", path: projectDir.path)
        configURL = root.appendingPathComponent("config.json")
        try ConfigStore(url: configURL).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [project],
            accounts: [AccountConfig(name: "default", configDir: "~/.claude")]))
    }

    private func makeState() -> AppState {
        let state = AppState(configStore: ConfigStore(url: configURL))
        state.statsStoreDirOverride = statsDir.path
        return state
    }

    private func reloadedConfig() -> GroveConfig {
        ConfigStore(url: configURL).load().config
    }

    /// `git add -A && git commit` in the project repo at a fixed date.
    private func commitAll(_ message: String, date: String) throws {
        let env = "GIT_AUTHOR_DATE='\(date)' GIT_COMMITTER_DATE='\(date)'"
        try FixtureLite.sh("\(env) git add -A && \(env) git commit -qm \(message)", cwd: projectDir)
    }

    // MARK: - refreshCodeStats

    func testRefreshCodeStatsTalliesAggregateAndGitHistory() async throws {
        let state = makeState()
        XCTAssertNil(state.codeStats[project.id])

        let now = Date(timeIntervalSince1970: 1_000_000)
        await state.refreshCodeStats(projectID: project.id, now: now)

        XCTAssertFalse(state.isStatsScanning)
        let stats = try XCTUnwrap(state.codeStats[project.id])
        // main.swift (3 code, 1 comment, 1 blank) + deep.swift (1) + vendor/lib (2).
        XCTAssertEqual(stats.totalFiles, 3)
        XCTAssertEqual(stats.code, 6)
        XCTAssertEqual(stats.scannedAt, now)

        // Per-repo breakdown is now published (one repo: the project itself).
        let repos = try XCTUnwrap(state.repoStats[project.id])
        XCTAssertEqual(repos.count, 1)
        XCTAssertEqual(repos.first?.stats.code, 6)

        // History is GIT-derived: one commit-day -> one point whose totalLines is the
        // cumulative net lines added in that commit (6 code + 2 non-code lines = 8).
        let history = try XCTUnwrap(state.codeStatsHistory[project.id])
        XCTAssertEqual(history.count, 1)
        let point = try XCTUnwrap(history.first)
        XCTAssertGreaterThan(point.totalLines, 0)
        XCTAssertEqual(point.totalLines, point.code, "history points carry net lines as totalLines==code")
    }

    func testRefreshCodeStatsHistoryIsGitDerivedAndStableAcrossScans() async throws {
        let state = makeState()
        await state.refreshCodeStats(projectID: project.id,
                                     now: Date(timeIntervalSince1970: 1_000_000))
        let first = try XCTUnwrap(state.codeStatsHistory[project.id])

        // A second scan (different `now`) yields the SAME git history — it's
        // authoritative and OVERWRITTEN each scan, not append-only. No new commits ->
        // identical series. Persisted to the store and reloaded by a fresh instance.
        let state2 = makeState()
        await state2.refreshCodeStats(projectID: project.id,
                                      now: Date(timeIntervalSince1970: 1_000_100))
        let second = try XCTUnwrap(state2.codeStatsHistory[project.id])
        XCTAssertEqual(second, first, "git history is stable when no commits were added")
        XCTAssertEqual(second.count, 1)
    }

    func testRefreshCodeStatsHistoryGrowsWithNewCommitDay() async throws {
        let state = makeState()
        await state.refreshCodeStats(projectID: project.id,
                                     now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(state.codeStatsHistory[project.id]?.count, 1)

        // A new commit on a LATER calendar day adds a second history point.
        try "let n = 1\n".write(to: projectDir.appendingPathComponent("new.swift"),
                                atomically: true, encoding: .utf8)
        try commitAll("c2", date: "2025-03-05T12:00:00Z")
        // Bust the per-repo cache the same way a real re-scan would (HEAD changed),
        // then re-scan.
        await state.refreshCodeStats(projectID: project.id,
                                     now: Date(timeIntervalSince1970: 1_000_200))
        let history = try XCTUnwrap(state.codeStatsHistory[project.id])
        XCTAssertEqual(history.count, 2, "a commit on a new day appends a history point")
        XCTAssertGreaterThan(history[1].totalLines, history[0].totalLines)
        XCTAssertEqual(state.codeStats[project.id]?.code, 7)  // + new.swift (1)
    }

    func testRefreshCodeStatsPublishesStatsFilesMatchingAggregate() async throws {
        let state = makeState()
        await state.refreshCodeStats(projectID: project.id,
                                     now: Date(timeIntervalSince1970: 1_000_000))

        let files = try XCTUnwrap(state.statsFiles[project.id])
        let stats = try XCTUnwrap(state.codeStats[project.id])
        // One entry per counted file; project-relative paths.
        XCTAssertEqual(files.count, stats.totalFiles)
        XCTAssertEqual(Set(files.map(\.path)),
                       ["main.swift", "sub/deep.swift", "vendor/lib.swift"])
        // Per-file lines sum to the aggregate total.
        let sum = files.reduce(0) { $0 + $1.lines }
        XCTAssertEqual(sum, stats.code + stats.comment + stats.blank)
    }

    func testSetStatsFolderExcludedTriggersRescanThatShrinksCountAndFiles() async throws {
        let state = makeState()
        await state.refreshCodeStats(projectID: project.id,
                                     now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(state.codeStats[project.id]?.code, 6)
        XCTAssertEqual(state.statsFiles[project.id]?.count, 3)

        // Excluding the `sub` folder fires an automatic rescan (no explicit refresh).
        state.setStatsFolderExcluded(projectID: project.id, relativePath: "sub", excluded: true)

        // Poll for the rescan Task to settle: sub/deep.swift (1 code) drops -> code 5.
        try await waitUntil { state.codeStats[self.project.id]?.code == 5 }
        XCTAssertEqual(state.codeStats[project.id]?.code, 5, "sub/deep.swift (1 code) excluded")
        let files = try XCTUnwrap(state.statsFiles[project.id])
        // The excluded folder's files STAY in the per-file list (flagged isExcluded)
        // so the settings tree keeps the folder + its re-include toggle reachable —
        // the count still shrank because excluded files don't reach the totals.
        XCTAssertEqual(files.count, 3, "excluded files remain in the list, flagged")
        let subFile = try XCTUnwrap(files.first { $0.path.hasPrefix("sub/") })
        XCTAssertTrue(subFile.isExcluded, "the excluded folder's file is flagged")
        // And the tree the settings page builds still surfaces the `sub` folder as an
        // excluded-but-re-includable node (enabled toggle: NOT excluded-by-ancestor).
        let nodes = buildFileTreeNodes(files: files, ignoredFolders: ["sub"])
        let subNode = try XCTUnwrap(nodes.first { $0.relativePath == "sub" })
        XCTAssertTrue(subNode.isExcluded)
        XCTAssertFalse(subNode.excludedByAncestor, "directly excluded -> toggle stays enabled")

        // Re-including restores them to the count.
        state.setStatsFolderExcluded(projectID: project.id, relativePath: "sub", excluded: false)
        try await waitUntil { state.codeStats[self.project.id]?.code == 6 }
        XCTAssertEqual(state.statsFiles[project.id]?.count, 3)
        XCTAssertFalse(state.statsFiles[project.id]?.contains { $0.isExcluded } ?? true)
    }

    // MARK: - setStatsBranch (Stats-tab branch switcher)

    func testSetStatsBranchUpdatesDictAndRescansWithOverride() async throws {
        let state = makeState()
        // Branch `alt` off main and add a commit ON A LATER DAY so its history has an
        // extra point the default (main) history lacks.
        try FixtureLite.sh("git -C \(shellQuote(projectDir.path)) checkout -qb alt")
        try "let a = 2\n".write(to: projectDir.appendingPathComponent("alt.swift"),
                               atomically: true, encoding: .utf8)
        try commitAll("alt-commit", date: "2025-03-07T12:00:00Z")
        // Leave HEAD on main so the working tree (and current LOC) match the default.
        try FixtureLite.sh("git -C \(shellQuote(projectDir.path)) checkout -q main")

        await state.refreshCodeStats(projectID: project.id,
                                     now: Date(timeIntervalSince1970: 1_000_000))
        // Default scan resolves to main: one commit-day, branch reported as main.
        let repoPath = try XCTUnwrap(state.repoStats[project.id]?.first?.repoPath)
        XCTAssertEqual(state.repoStats[project.id]?.first?.defaultBranch, "main")
        XCTAssertEqual(state.codeStatsHistory[project.id]?.count, 1)

        // Switch the branch: the dict updates and a rescan fires (no explicit refresh).
        state.setStatsBranch(projectID: project.id, repoPath: repoPath, branch: "alt")
        XCTAssertEqual(state.selectedStatsBranchByRepo[repoPath], "alt",
                       "override recorded immediately")

        // The rescan settles with the override applied: effective branch is `alt` and
        // its history now carries the extra commit-day -> 2 points.
        try await waitUntil { state.repoStats[self.project.id]?.first?.defaultBranch == "alt" }
        XCTAssertEqual(state.codeStatsHistory[project.id]?.count, 2,
                       "alt branch's extra commit-day shows up in the rescanned history")
        // The switcher's options were loaded for the repo (loadBranches ran in the scan).
        let branches = try XCTUnwrap(state.branchesByRepo[repoPath])
        XCTAssertTrue(branches.contains("alt") && branches.contains("main"))
    }

    func testRemoveProjectClearsStatsBranchOverrides() async throws {
        let state = makeState()
        await state.refreshCodeStats(projectID: project.id,
                                     now: Date(timeIntervalSince1970: 1_000_000))
        let repoPath = try XCTUnwrap(state.repoStats[project.id]?.first?.repoPath)

        state.setStatsBranch(projectID: project.id, repoPath: repoPath, branch: "main")
        XCTAssertEqual(state.selectedStatsBranchByRepo[repoPath], "main")
        // Let the rescan triggered by setStatsBranch settle before tearing down.
        try await waitUntil { !state.isStatsScanning }

        state.removeProject(id: project.id)
        XCTAssertNil(state.selectedStatsBranchByRepo[repoPath],
                     "branch override cleared on removeProject")
    }

    /// Polls `condition` on the main actor until true or a timeout, yielding to let
    /// the rescan `Task` (launched by `setStatsFolderExcluded`) run to completion.
    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 20_000_000)  // 20ms
        }
    }

    func testRefreshCodeStatsUnknownProjectIsNoOp() async {
        let state = makeState()
        await state.refreshCodeStats(projectID: UUID())
        XCTAssertTrue(state.codeStats.isEmpty)
        XCTAssertFalse(state.isStatsScanning)
    }

    // MARK: - gitignore exclusion (git's own engine drives what's counted)

    func testGitignoredFolderIsExcludedFromCount() async throws {
        let state = makeState()
        await state.refreshCodeStats(projectID: project.id,
                                     now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(state.codeStats[project.id]?.code, 6)

        // .gitignore the vendor folder and commit it -> git stops listing vendor/lib.swift.
        try "vendor/\n".write(to: projectDir.appendingPathComponent(".gitignore"),
                              atomically: true, encoding: .utf8)
        try FixtureLite.sh("git -C \(shellQuote(projectDir.path)) rm -q -r --cached vendor")
        try commitAll("ignore-vendor", date: "2025-03-06T12:00:00Z")

        await state.refreshCodeStats(projectID: project.id,
                                     now: Date(timeIntervalSince1970: 1_000_200))
        let stats = try XCTUnwrap(state.codeStats[project.id])
        XCTAssertEqual(stats.code, 4, "vendor/lib.swift (2 code) excluded via .gitignore")
        // Only recognized-extension files are classified: main.swift + sub/deep.swift.
        // (.gitignore has no recognized extension; vendor/lib.swift is now ignored.)
        XCTAssertEqual(stats.totalFiles, 2)
    }

    // MARK: - setStatsFolderExcluded (picker config persistence + re-scan trigger)

    func testSetStatsFolderExcludedPersistsConfigAndReScans() async throws {
        let state = makeState()
        await state.refreshCodeStats(projectID: project.id,
                                     now: Date(timeIntervalSince1970: 1_000_000))

        state.setStatsFolderExcluded(projectID: project.id, relativePath: "vendor", excluded: true)
        XCTAssertEqual(state.config.projects.first?.statsIgnoredFolders, ["vendor"])
        XCTAssertEqual(reloadedConfig().projects.first?.statsIgnoredFolders, ["vendor"])

        // The toggle now ACTUALLY changes the numbers (the prior bug: it didn't). A
        // path-level exclusion of `vendor` drops vendor/lib.swift (2 code) from the
        // count via the new excludedFolders pass — independent of git's own ignore
        // engine. An explicit re-scan settles to the reduced total.
        await state.refreshCodeStats(projectID: project.id,
                                     now: Date(timeIntervalSince1970: 1_000_200))
        XCTAssertFalse(state.isStatsScanning)
        XCTAssertEqual(state.codeStats[project.id]?.code, 4, "vendor/lib.swift (2 code) excluded by folder toggle")
    }

    func testSetStatsFolderReIncludeRemovesFromConfig() {
        let state = makeState()
        state.setStatsFolderExcluded(projectID: project.id, relativePath: "vendor", excluded: true)
        state.setStatsFolderExcluded(projectID: project.id, relativePath: "vendor", excluded: false)
        XCTAssertEqual(state.config.projects.first?.statsIgnoredFolders, [])
    }

    func testSetStatsFolderExcludedIdempotent() {
        let state = makeState()
        state.setStatsFolderExcluded(projectID: project.id, relativePath: "vendor", excluded: true)
        state.setStatsFolderExcluded(projectID: project.id, relativePath: "vendor", excluded: true)
        XCTAssertEqual(state.config.projects.first?.statsIgnoredFolders, ["vendor"])
    }

    // MARK: - directory tree

    func testStatsDirectoryTreeEmitsFoldersForPicker() async throws {
        let state = makeState()
        let tree = await state.statsDirectoryTree(projectID: project.id)
        let root = try XCTUnwrap(tree)
        // The skeleton walks directories only; the project root carries the two folders.
        XCTAssertEqual(Set(root.children.map(\.relativePath)), ["sub", "vendor"])
    }

    // MARK: - removeProject cleanup

    func testRemoveProjectClearsStatsStateAndDeletesHistoryFile() async {
        let state = makeState()
        await state.refreshCodeStats(projectID: project.id,
                                     now: Date(timeIntervalSince1970: 1_000_000))
        let historyFile = statsDir.appendingPathComponent("\(project.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyFile.path))

        state.removeProject(id: project.id)

        XCTAssertNil(state.codeStats[project.id])
        XCTAssertNil(state.codeStatsHistory[project.id])
        XCTAssertNil(state.repoStats[project.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyFile.path),
                       "the per-project history file must be deleted on removeProject")
    }
}
