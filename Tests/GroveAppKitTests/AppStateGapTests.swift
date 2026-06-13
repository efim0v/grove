import XCTest
import GroveCore
@testable import GroveAppKit

@MainActor
final class AppStateGapTests: XCTestCase {
    private var configURL: URL!
    private var root: URL!

    override func setUp() async throws {
        root = try FixtureLite.tempDir("appstate-gap")
        configURL = root.appendingPathComponent("config.json")
    }

    private func state(_ runner: ScriptedRunner = ScriptedRunner(responses: ["ping": .ok("PONG")])) -> AppState {
        let s = AppState(configStore: ConfigStore(url: configURL))
        s.cmuxOverride = stubbedCmux(runner)
        s.canonicalDirOverride = root.appendingPathComponent("canonical").path
        return s
    }

    func testProjectCrudModelEffortAndSelection() {
        let s = state()
        s.addProject(at: "/tmp/grove-demo")
        let id = s.selectedProjectID!
        XCTAssertEqual(s.selectedProject?.name, "grove-demo")
        s.setProjectModel(projectID: id, model: "claude-opus-4-8")
        s.setProjectEffort(projectID: id, effort: "high")
        XCTAssertEqual(s.selectedProject?.defaultModel, "claude-opus-4-8")
        XCTAssertEqual(s.selectedProject?.defaultEffort, "high")
        s.setProjectModel(projectID: id, model: "")     // empty clears
        s.setProjectEffort(projectID: id, effort: "")
        XCTAssertNil(s.selectedProject?.defaultModel)
        XCTAssertNil(s.selectedProject?.defaultEffort)
        s.updateProject(ProjectConfig(name: "ghost", path: "/x"))   // unknown id -> no-op
        XCTAssertEqual(s.config.projects.count, 1)
        s.removeProject(id: id)
        XCTAssertTrue(s.config.projects.isEmpty)
        XCTAssertNil(s.selectedProjectID)
    }

    func testAccountCrudRejectsDuplicates() {
        let s = state()
        let initial = s.config.accounts.count
        s.addAccount(name: "work")
        XCTAssertTrue(s.config.accounts.contains { $0.name == "work" })
        XCTAssertEqual(s.config.accounts.count, initial + 1)
        s.addAccount(name: "work")        // duplicate
        XCTAssertNotNil(s.actionError)
        XCTAssertEqual(s.config.accounts.count, initial + 1, "duplicate not added")
        s.removeAccount(name: "work")
        XCTAssertFalse(s.config.accounts.contains { $0.name == "work" })
    }

    func testWorkspacesRootTemplatePersists() {
        let s = state()
        s.setWorkspacesRootTemplate("~/Code/{project}")
        XCTAssertEqual(s.config.workspacesRootTemplate, "~/Code/{project}")
    }

    func testGoToCmuxAndOpenShellRecordCalls() async {
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let s = state(runner)
        await s.goToCmux(CmuxWorkspace(id: "ws-1", title: "t", currentDirectory: "/a"))
        XCTAssertEqual(runner.calls(startingWith: "select-workspace").first?.args,
                       ["select-workspace", "--workspace", "ws-1"])
        await s.openCmuxShell(cwd: "/a", title: "shell")
        XCTAssertEqual(runner.calls(startingWith: "new-workspace").count, 1)
    }

    func testAggregateRemainingUsesLatestCaptureAndTierWeight() {
        let s = state()
        s.config.accounts = [AccountConfig(name: "a", configDir: "/tmp/a")]
        s.tierOverride = ["a": "default_claude_max_5x"]
        s.snapshotsByAccount = ["a": [UsageSnapshot(
            accountName: "a", sessionId: "s", capturedAt: Date(), cwd: nil, modelId: nil,
            modelDisplayName: nil, effort: nil, contextUsedPercentage: nil, totalInputTokens: nil,
            totalCostUSD: nil, fiveHour: CapturedWindow(usedPercentage: 40, resetsAt: nil),
            sevenDay: nil)]]
        let agg = s.aggregateRemaining(window: .fiveHour, now: Date())
        XCTAssertEqual(agg.total, 5, accuracy: 1e-9)
        XCTAssertEqual(agg.remaining, 5 * 0.6, accuracy: 1e-9)
    }

    func testInstallAndDisableMonitoringToggleFlag() throws {
        let s = state()
        s.statuslineScriptDirOverride = root.appendingPathComponent("bin").path
        let dir = root.appendingPathComponent("acct-claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        s.config.accounts = [AccountConfig(name: "work", configDir: dir.path)]
        s.installMonitoring(s.config.accounts[0])
        XCTAssertTrue(s.config.accounts[0].monitoring)
        s.disableMonitoring(s.config.accounts[0])
        XCTAssertFalse(s.config.accounts[0].monitoring)
    }
}
