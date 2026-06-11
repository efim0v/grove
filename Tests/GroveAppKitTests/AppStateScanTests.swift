import XCTest
import GroveCore
@testable import GroveAppKit

@MainActor
final class AppStateScanTests: XCTestCase {
    // Layout built in setUp:
    //   <root>/project/alpha             main checkout on `main`
    //   <root>/workspaces/feat-x/alpha   worktree on feat/x, one commit ahead of main
    //   <root>/claude-home               account configDir that simply does not exist
    //                                    -> zero sessions, zero live processes
    private var root: URL!
    private var configURL: URL!
    private var project: ProjectConfig!

    override func setUp() async throws {
        root = try FixtureLite.tempDir("appstate-scan")
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)

        let repo = try FixtureLite.makeRepo(in: projectDir, name: "alpha")
        let worktree = workspacesRoot.appendingPathComponent("feat-x/alpha", isDirectory: true)
        try FixtureLite.addWorktree(repo: repo, branch: "feat/x", from: "main", at: worktree)
        try FixtureLite.commit(repo: worktree, file: "x.txt", content: "x\n", message: "feature work")

        project = ProjectConfig(name: "project", path: projectDir.path,
                                workspacesRoot: workspacesRoot.path)
        configURL = root.appendingPathComponent("config.json")
        try ConfigStore(url: configURL).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [project],
            accounts: [AccountConfig(name: "test",
                                     configDir: root.appendingPathComponent("claude-home").path)]))
    }

    private func makeState() -> AppState {
        let state = AppState(configStore: ConfigStore(url: configURL))
        state.cmuxOverride = stubbedCmux()   // unit tests must never invoke real cmux
        return state
    }

    func testRefreshScansSelectedProjectIntoSnapshots() async throws {
        let state = makeState()
        XCTAssertNil(state.selectedSnapshot)

        await state.refresh()

        XCTAssertFalse(state.isScanning)
        let snapshot = try XCTUnwrap(state.selectedSnapshot)
        XCTAssertEqual(snapshot.repos.map { $0.dirName }, ["alpha"])
        XCTAssertEqual(snapshot.workspaces.map { $0.name }, ["feat-x"])
        XCTAssertTrue(snapshot.loose.isEmpty)
        XCTAssertTrue(snapshot.errors.isEmpty)

        let ws = try XCTUnwrap(snapshot.workspaces.first)
        XCTAssertNil(ws.parentName)
        XCTAssertEqual(ws.repos.count, 1)
        XCTAssertEqual(ws.repos.first?.entry.branch, "feat/x")
        XCTAssertEqual(ws.repos.first?.meta?.baseBranch, "main")
        XCTAssertEqual(ws.repos.first?.meta?.ahead, 1)
        XCTAssertEqual(ws.repos.first?.meta?.behind, 0)
        XCTAssertTrue(ws.sessions.isEmpty)
        XCTAssertTrue(ws.liveProcesses.isEmpty)
    }

    func testRefreshWithoutSelectionIsANoOp() async {
        let state = makeState()
        state.selectedProjectID = nil
        await state.refresh()
        XCTAssertTrue(state.snapshots.isEmpty)
        XCTAssertFalse(state.isScanning)
    }

    func testRefreshedSnapshotFeedsTreeModel() async throws {
        let state = makeState()
        await state.refresh()
        let snapshot = try XCTUnwrap(state.selectedSnapshot)
        let rows = buildWorkspaceTree(snapshot, now: Date())
        XCTAssertEqual(rows.map { $0.name }, ["feat-x"])
        XCTAssertEqual(rows.first?.depth, 0)
        XCTAssertEqual(rows.first?.badges.ageBucket, .fresh)
    }
}
