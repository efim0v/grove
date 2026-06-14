import XCTest
import GroveCore
@testable import GroveAppKit

@MainActor
final class AppStateCodeStatsTests: XCTestCase {
    private var root: URL!
    private var statsDir: URL!
    private var configURL: URL!
    private var project: ProjectConfig!

    // Layout built in setUp under <root>/project:
    //   main.swift             3 code, 1 comment, 1 blank
    //   sub/deep.swift         1 code
    //   vendor/lib.swift       2 code   (excludable via statsIgnoredFolders)
    override func setUp() async throws {
        root = try FixtureLite.tempDir("appstate-codestats")
        statsDir = root.appendingPathComponent("stats")
        let projectDir = root.appendingPathComponent("project")
        let fm = FileManager.default
        try fm.createDirectory(at: projectDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: projectDir.appendingPathComponent("vendor"), withIntermediateDirectories: true)
        try "import Foundation\n// a comment\n\nlet x = 1\nprint(x)\n"
            .write(to: projectDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "let d = 1\n"
            .write(to: projectDir.appendingPathComponent("sub/deep.swift"), atomically: true, encoding: .utf8)
        try "let v = 1\nlet v2 = 2\n"
            .write(to: projectDir.appendingPathComponent("vendor/lib.swift"), atomically: true, encoding: .utf8)

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

    // MARK: - refreshCodeStats

    func testRefreshCodeStatsTalliesAndAppendsHistory() async throws {
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

        // First refresh seeds one history point matching the scan totals.
        let history = try XCTUnwrap(state.codeStatsHistory[project.id])
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.code, 6)
        XCTAssertEqual(history.first?.totalFiles, 3)
        XCTAssertEqual(history.first?.date, now)
    }

    func testRefreshCodeStatsPersistsHistoryAcrossInstances() async throws {
        let state = makeState()
        await state.refreshCodeStats(projectID: project.id,
                                     now: Date(timeIntervalSince1970: 1_000_000))

        // A fresh AppState pointed at the same stats dir loads the persisted series
        // on its next refresh (and coalesces a same-totals point onto the trailing one).
        let state2 = makeState()
        await state2.refreshCodeStats(projectID: project.id,
                                      now: Date(timeIntervalSince1970: 1_000_100))
        let history = try XCTUnwrap(state2.codeStatsHistory[project.id])
        // Same totals within minInterval -> the trailing point is REPLACED, not grown.
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.date, Date(timeIntervalSince1970: 1_000_100))
    }

    func testRefreshCodeStatsUnknownProjectIsNoOp() async {
        let state = makeState()
        await state.refreshCodeStats(projectID: UUID())
        XCTAssertTrue(state.codeStats.isEmpty)
        XCTAssertFalse(state.isStatsScanning)
    }

    // MARK: - setStatsFolderExcluded

    func testSetStatsFolderExcludedPersistsAndChangesNextScan() async throws {
        let state = makeState()
        await state.refreshCodeStats(projectID: project.id,
                                     now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(state.codeStats[project.id]?.code, 6)

        state.setStatsFolderExcluded(projectID: project.id, relativePath: "vendor", excluded: true)
        XCTAssertEqual(state.config.projects.first?.statsIgnoredFolders, ["vendor"])
        XCTAssertEqual(reloadedConfig().projects.first?.statsIgnoredFolders, ["vendor"])

        // Re-scan: vendor/lib.swift (2 code) is dropped -> 4 code, 2 files.
        await state.refreshCodeStats(projectID: project.id,
                                     now: Date(timeIntervalSince1970: 1_000_200))
        let stats = try XCTUnwrap(state.codeStats[project.id])
        XCTAssertEqual(stats.code, 4)
        XCTAssertEqual(stats.totalFiles, 2)
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyFile.path),
                       "the per-project history file must be deleted on removeProject")
    }
}
