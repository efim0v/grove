import XCTest
import GroveCore
@testable import GroveAppKit

@MainActor
final class AppStateConfigTests: XCTestCase {
    private var configURL: URL!

    override func setUp() async throws {
        configURL = try FixtureLite.tempDir("appstate-config").appendingPathComponent("config.json")
    }

    private func makeState() -> AppState {
        AppState(configStore: ConfigStore(url: configURL))
    }

    private func reloadedConfig() -> GroveConfig {
        ConfigStore(url: configURL).load().config
    }

    // MARK: - init

    func testInitWithMissingFileLoadsDefaultsAndNoIssue() {
        let state = makeState()
        XCTAssertEqual(state.config, .defaultConfig)
        XCTAssertNil(state.configIssue)
        XCTAssertNil(state.selectedProjectID)
        XCTAssertNil(state.selectedSnapshot)
        XCTAssertEqual(state.selectedTab, .workspaces)
        XCTAssertEqual(state.searchQuery, "")
        XCTAssertFalse(state.isScanning)
        XCTAssertNil(state.actionError)
        XCTAssertTrue(state.graphNodes.isEmpty)
    }

    func testInitSelectsFirstProject() throws {
        let project = ProjectConfig(name: "demo", path: "/tmp/demo")
        try ConfigStore(url: configURL).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [project],
            accounts: [AccountConfig(name: "default", configDir: "~/.claude")]))
        let state = makeState()
        XCTAssertEqual(state.selectedProjectID, project.id)
        XCTAssertEqual(state.selectedProject?.name, "demo")
    }

    func testInitSurfacesCorruptConfigIssueAndFallsBackToDefaults() throws {
        try Data("{this is not json".utf8).write(to: configURL)
        let state = makeState()
        XCTAssertNotNil(state.configIssue)
        XCTAssertEqual(state.config, .defaultConfig)
    }

    // MARK: - projects

    func testAddProjectNamesAfterLeafDirSavesAndSelects() throws {
        let state = makeState()
        state.addProject(at: "/tmp/parent/my-project")
        let project = try XCTUnwrap(state.config.projects.first)
        XCTAssertEqual(project.name, "my-project")
        XCTAssertEqual(project.path, "/tmp/parent/my-project")
        XCTAssertEqual(project.branchTemplate, "feat/{name}")
        XCTAssertEqual(state.selectedProjectID, project.id)
        XCTAssertEqual(reloadedConfig().projects.map { $0.name }, ["my-project"])
    }

    func testAddProjectExpandsTilde() throws {
        let state = makeState()
        state.addProject(at: "~/Desktop/thing")
        let project = try XCTUnwrap(state.config.projects.first)
        XCTAssertEqual(project.path, NSHomeDirectory() + "/Desktop/thing")
        XCTAssertEqual(project.name, "thing")
    }

    func testRemoveProjectReselectsFirstRemainingAndPersists() throws {
        let state = makeState()
        state.addProject(at: "/tmp/a")
        let aID = try XCTUnwrap(state.selectedProjectID)
        state.addProject(at: "/tmp/b")
        let bID = try XCTUnwrap(state.selectedProjectID)
        XCTAssertNotEqual(aID, bID)

        state.removeProject(id: bID)
        XCTAssertEqual(state.selectedProjectID, aID)
        XCTAssertEqual(state.config.projects.map { $0.name }, ["a"])

        state.removeProject(id: aID)
        XCTAssertNil(state.selectedProjectID)
        XCTAssertTrue(reloadedConfig().projects.isEmpty)
    }

    func testRemoveNonSelectedProjectKeepsSelection() throws {
        let state = makeState()
        state.addProject(at: "/tmp/a")
        let aID = try XCTUnwrap(state.selectedProjectID)
        state.addProject(at: "/tmp/b")
        let bID = try XCTUnwrap(state.selectedProjectID)

        state.removeProject(id: aID)
        XCTAssertEqual(state.selectedProjectID, bID)
    }

    func testRemoveProjectDropsItsSnapshot() throws {
        let state = makeState()
        state.addProject(at: "/tmp/a")
        let id = try XCTUnwrap(state.selectedProjectID)
        state.snapshots[id] = Fix.snapshot(workspaces: [Fix.workspace(name: "w")])
        XCTAssertNotNil(state.selectedSnapshot)

        state.removeProject(id: id)
        XCTAssertTrue(state.snapshots.isEmpty)
    }

    func testUpdateProjectReplacesByIdAndPersists() throws {
        let state = makeState()
        state.addProject(at: "/tmp/a")
        var project = try XCTUnwrap(state.config.projects.first)
        project.branchTemplate = "wip/{name}"
        project.excludedRepos = ["vendor"]
        state.updateProject(project)
        XCTAssertEqual(state.config.projects.first?.branchTemplate, "wip/{name}")
        XCTAssertEqual(reloadedConfig().projects.first?.excludedRepos, ["vendor"])
    }

    func testUpdateProjectWithUnknownIdIsIgnored() {
        let state = makeState()
        state.addProject(at: "/tmp/a")
        state.updateProject(ProjectConfig(name: "ghost", path: "/tmp/ghost"))
        XCTAssertEqual(state.config.projects.map { $0.name }, ["a"])
    }

    // MARK: - global settings

    func testSetWorkspacesRootTemplatePersists() {
        let state = makeState()
        state.setWorkspacesRootTemplate("~/Forest/{project}")
        XCTAssertEqual(state.config.workspacesRootTemplate, "~/Forest/{project}")
        XCTAssertEqual(reloadedConfig().workspacesRootTemplate, "~/Forest/{project}")
    }

    // MARK: - accounts

    func testAddAccountBuildsConventionalConfigDirAndPersists() {
        let state = makeState()
        state.addAccount(name: "work")
        XCTAssertEqual(state.config.accounts.last,
                       AccountConfig(name: "work", configDir: "~/.claude-accounts/work"))
        XCTAssertEqual(reloadedConfig().accounts.map { $0.name }, ["default", "work"])
        XCTAssertNil(state.actionError)
    }

    func testAddDuplicateAccountSetsActionErrorAndDoesNotDuplicate() {
        let state = makeState()
        state.addAccount(name: "work")
        state.addAccount(name: "work")
        XCTAssertEqual(state.config.accounts.filter { $0.name == "work" }.count, 1)
        XCTAssertNotNil(state.actionError)
    }

    func testRemoveAccountPersists() {
        let state = makeState()
        state.addAccount(name: "work")
        state.removeAccount(name: "work")
        XCTAssertEqual(state.config.accounts.map { $0.name }, ["default"])
        XCTAssertEqual(reloadedConfig().accounts.map { $0.name }, ["default"])
    }

    // MARK: - selection

    func testSelectedSnapshotFollowsSelection() throws {
        let state = makeState()
        state.addProject(at: "/tmp/a")
        let aID = try XCTUnwrap(state.selectedProjectID)
        state.addProject(at: "/tmp/b")
        let snapshot = Fix.snapshot(workspaces: [Fix.workspace(name: "only-a")])
        state.snapshots[aID] = snapshot

        XCTAssertNil(state.selectedSnapshot)        // b selected, no snapshot
        state.selectedProjectID = aID
        XCTAssertEqual(state.selectedSnapshot, snapshot)
    }
}
