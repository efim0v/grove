import XCTest
import GroveCore
@testable import GroveAppKit

/// Route model + AppState navigation helpers: the panel is a state machine of
/// full-screen views; open()/goBack() drive it with an explicit back-map and
/// a push/pop direction derived from route depth.
@MainActor
final class RouteTests: XCTestCase {
    private let id = UUID()

    // MARK: - Pure route model

    func testDepthsCompareGeneralToSpecific() {
        XCTAssertEqual(Route.projects.depth, 0)
        XCTAssertEqual(Route.project(id).depth, 1)
        XCTAssertEqual(Route.accounts.depth, 1)
        XCTAssertEqual(Route.globalSettings.depth, 1)
        XCTAssertEqual(Route.projectSettings(id).depth, 2)
        XCTAssertEqual(Route.createWorkspace(id).depth, 2)
    }

    func testExplicitBackMap() {
        XCTAssertEqual(Route.createWorkspace(id).backRoute, .project(id))
        XCTAssertEqual(Route.projectSettings(id).backRoute, .project(id))
        XCTAssertEqual(Route.project(id).backRoute, .projects)
        XCTAssertEqual(Route.accounts.backRoute, .projects)
        XCTAssertEqual(Route.globalSettings.backRoute, .projects)
        XCTAssertEqual(Route.projects.backRoute, .projects)   // root: stays put
    }

    // MARK: - AppState navigation

    /// Hermetic state: temp config path, scan-safe project layout (existing
    /// empty dirs, account configDir that does not exist), stubbed cmux.
    private func makeState() throws -> (state: AppState, projectID: UUID) {
        let root = try FixtureLite.tempDir("route")
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
        let project = ProjectConfig(name: "project", path: projectDir.path,
                                    workspacesRoot: workspacesRoot.path)
        let configURL = root.appendingPathComponent("config.json")
        try ConfigStore(url: configURL).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [project],
            accounts: [AccountConfig(name: "test",
                                     configDir: root.appendingPathComponent("claude-home").path)]))
        let state = AppState(configStore: ConfigStore(url: configURL))
        state.cmuxOverride = stubbedCmux()   // unit tests must never invoke real cmux
        return (state, project.id)
    }

    func testInitialRouteIsProjectsWithNoPrefill() throws {
        let (state, _) = try makeState()
        XCTAssertEqual(state.route, .projects)
        XCTAssertNil(state.createPrefill)
        XCTAssertTrue(state.routeIsForward)
    }

    func testOpenSetsRouteAndForwardDirection() throws {
        let (state, _) = try makeState()
        state.open(.accounts)
        XCTAssertEqual(state.route, .accounts)
        XCTAssertTrue(state.routeIsForward)
    }

    func testOpenProjectSetsSelectionAndTriggersRefresh() async throws {
        let (state, projectID) = try makeState()
        state.selectedProjectID = nil               // prove open() re-selects
        XCTAssertNil(state.selectedSnapshot)

        state.open(.project(projectID))

        XCTAssertEqual(state.route, .project(projectID))
        XCTAssertEqual(state.selectedProjectID, projectID)
        await state.refreshTask?.value
        XCTAssertNotNil(state.snapshots[projectID], "open(.project) must trigger a scan")
    }

    func testGoBackFollowsBackMapAndSetsBackwardDirection() async throws {
        let (state, projectID) = try makeState()
        state.open(.project(projectID))
        state.open(.projectSettings(projectID))
        XCTAssertTrue(state.routeIsForward)

        state.goBack()
        XCTAssertEqual(state.route, .project(projectID))
        XCTAssertFalse(state.routeIsForward)

        state.goBack()
        XCTAssertEqual(state.route, .projects)
        XCTAssertFalse(state.routeIsForward)
        await state.refreshTask?.value              // drain the open(.project) scan
    }

    func testGoBackFromCreateWorkspaceConsumesPrefillAndReturnsToProject() async throws {
        let (state, projectID) = try makeState()
        state.open(.project(projectID))
        state.createPrefill = CreatePrefill(name: "checkout-flow")
        state.open(.createWorkspace(projectID))
        XCTAssertEqual(state.route, .createWorkspace(projectID))
        XCTAssertNotNil(state.createPrefill)

        state.goBack()
        XCTAssertEqual(state.route, .project(projectID))
        XCTAssertNil(state.createPrefill, "prefill is consumed when leaving createWorkspace")
        await state.refreshTask?.value
    }

    func testGoBackAtRootIsANoOp() throws {
        let (state, _) = try makeState()
        state.goBack()
        XCTAssertEqual(state.route, .projects)
    }
}
