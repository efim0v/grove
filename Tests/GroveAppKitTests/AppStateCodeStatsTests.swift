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

        // A re-scan after the toggle still settles cleanly (the count comes from git's
        // own ignore engine now, so a non-gitignored folder remains counted).
        await state.refreshCodeStats(projectID: project.id,
                                     now: Date(timeIntervalSince1970: 1_000_200))
        XCTAssertFalse(state.isStatsScanning)
        XCTAssertEqual(state.codeStats[project.id]?.code, 6)
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
        let rows = buildStatsTree(root, ignoredFolders: ["vendor"])
        XCTAssertEqual(Set(rows.map(\.relativePath)), ["sub", "vendor"])
        let vendor = try XCTUnwrap(rows.first { $0.relativePath == "vendor" })
        XCTAssertTrue(vendor.isExcluded)
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
        XCTAssertNil(state.codeStatsDelta[project.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyFile.path),
                       "the per-project history file must be deleted on removeProject")
    }
}
