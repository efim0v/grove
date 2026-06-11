import XCTest
import GroveCore
@testable import GroveAppKit

/// v1.2.1 fix 1: the Graph tab must never render commits of a previously
/// selected project. AppState clears graphNodes/graphRepoPath/graphCanLoadMore
/// when the selection moves to a DIFFERENT project (open(.project)) or when
/// the selected project is removed; GraphScreen then re-selects a repo via the
/// pure graphAutoSelectRepo helper (tested here without UI).
@MainActor
final class GraphProjectSwitchTests: XCTestCase {
    private var repoA: URL!
    private var projectA: ProjectConfig!
    private var projectB: ProjectConfig!
    private var configURL: URL!

    override func setUp() async throws {
        let root = try FixtureLite.tempDir("graph-switch")
        let dirA = root.appendingPathComponent("alpha", isDirectory: true)
        let dirB = root.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        repoA = try FixtureLite.makeRepo(in: dirA, name: "repo-a")
        _ = try FixtureLite.makeRepo(in: dirB, name: "repo-b")
        projectA = ProjectConfig(name: "alpha", path: dirA.path)
        projectB = ProjectConfig(name: "beta", path: dirB.path)
        configURL = root.appendingPathComponent("config.json")
        try ConfigStore(url: configURL).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [projectA, projectB], accounts: []))
    }

    private func makeState() -> AppState {
        let state = AppState(configStore: ConfigStore(url: configURL))
        state.cmuxOverride = stubbedCmux()   // unit tests must never invoke real cmux
        // repo-a has exactly one commit; pageSize 1 makes the page "full" so
        // graphCanLoadMore turns true and its clearing is observable.
        state.graphPageSize = 1
        return state
    }

    /// Opens project A and loads its graph — the state every test starts from.
    private func openProjectAAndLoadGraph(_ state: AppState) async {
        state.open(.project(projectA.id))
        await state.refreshTask?.value
        await state.loadGraph(repoPath: repoA.path)
        XCTAssertEqual(state.graphNodes.map(\.subject), ["base"])
        XCTAssertEqual(state.graphRepoPath, repoA.path)
        XCTAssertTrue(state.graphCanLoadMore)
    }

    // MARK: - AppState clearing

    func testOpeningAnotherProjectClearsGraphState() async {
        let state = makeState()
        await openProjectAAndLoadGraph(state)

        state.open(.project(projectB.id))

        XCTAssertTrue(state.graphNodes.isEmpty,
                      "project B must not render project A's commits")
        XCTAssertNil(state.graphRepoPath)
        XCTAssertFalse(state.graphCanLoadMore)
        await state.refreshTask?.value   // don't leak the scan beyond the test
    }

    func testReopeningTheSameProjectKeepsGraphState() async {
        let state = makeState()
        await openProjectAAndLoadGraph(state)

        state.open(.project(projectA.id))

        XCTAssertEqual(state.graphNodes.map(\.subject), ["base"],
                       "same project — a loaded graph survives re-entry")
        XCTAssertEqual(state.graphRepoPath, repoA.path)
        XCTAssertTrue(state.graphCanLoadMore)
        await state.refreshTask?.value
    }

    func testRemovingTheSelectedProjectClearsGraphState() async {
        let state = makeState()
        await openProjectAAndLoadGraph(state)

        state.removeProject(id: projectA.id)

        XCTAssertTrue(state.graphNodes.isEmpty)
        XCTAssertNil(state.graphRepoPath)
        XCTAssertFalse(state.graphCanLoadMore)
    }

    func testRemovingAnotherProjectKeepsGraphState() async {
        let state = makeState()
        await openProjectAAndLoadGraph(state)

        state.removeProject(id: projectB.id)

        XCTAssertEqual(state.graphNodes.map(\.subject), ["base"])
        XCTAssertEqual(state.graphRepoPath, repoA.path)
    }

    // MARK: - Auto-select helper (GraphScreen's .task logic, pure)

    func testAutoSelectPicksFirstRepoWhenSelectionIsNilOrStale() {
        let repos = [RepoInfo(path: "/p/a", dirName: "a"),
                     RepoInfo(path: "/p/b", dirName: "b")]
        XCTAssertEqual(graphAutoSelectRepo(current: nil, repos: repos)?.path, "/p/a")
        XCTAssertEqual(graphAutoSelectRepo(current: "/other/repo", repos: repos)?.path, "/p/a",
                       "selection left over from another project is stale")
    }

    func testAutoSelectLeavesAValidSelectionAlone() {
        let repos = [RepoInfo(path: "/p/a", dirName: "a"),
                     RepoInfo(path: "/p/b", dirName: "b")]
        XCTAssertNil(graphAutoSelectRepo(current: "/p/b", repos: repos),
                     "valid selection — no reload")
    }

    func testAutoSelectWithNoReposReturnsNil() {
        XCTAssertNil(graphAutoSelectRepo(current: nil, repos: []))
        XCTAssertNil(graphAutoSelectRepo(current: "/p/a", repos: []))
    }
}
