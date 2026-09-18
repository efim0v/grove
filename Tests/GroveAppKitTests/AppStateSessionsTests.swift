import XCTest
import GroveCore
@testable import GroveAppKit

@MainActor
final class AppStateSessionsTests: XCTestCase {
    private var root: URL!
    private var configURL: URL!

    override func setUp() async throws {
        root = try FixtureLite.tempDir("appstate-sessions")
        configURL = root.appendingPathComponent("config.json")
    }

    private func makeState(_ runner: ScriptedRunner) -> AppState {
        let state = AppState(configStore: ConfigStore(url: configURL))
        state.cmuxOverride = stubbedCmux(runner)
        state.canonicalDirOverride = root.appendingPathComponent("canonical").path
        return state
    }

    // MARK: - openSession

    func testOpenSessionGoSelectsCmuxWorkspace() async throws {
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner)
        state.config.accounts = [AccountConfig(name: "default", configDir: "/tmp/x")]
        let row = ProjectSessionRow(sessionId: "s1", title: "T", cwd: "/ws/a", location: "a",
                                    accountName: "default", lastActivity: Date(),
                                    status: .running, cmuxWorkspaceId: "ws-9")
        await state.openSession(row)
        XCTAssertNil(state.actionError)
        XCTAssertEqual(runner.calls(startingWith: "select-workspace").first?.args,
                       ["select-workspace", "--workspace", "ws-9"])
        XCTAssertTrue(runner.calls(startingWith: "new-workspace").isEmpty)
    }

    func testOpenSessionClosedPresentsLaunchSheetThenResumes() async throws {
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner)
        state.config.accounts = [AccountConfig(name: "work", configDir: "/tmp/grove-work")]
        let row = ProjectSessionRow(sessionId: "abc", title: "T", cwd: "/ws/a", location: "a",
                                    accountName: "work", lastActivity: Date(),
                                    status: .closed, cmuxWorkspaceId: nil)
        // A closed session now opens the launch sheet (no process spawned yet).
        await state.openSession(row)
        XCTAssertTrue(runner.calls(startingWith: "new-workspace").isEmpty)
        let req = try XCTUnwrap(state.launchRequest)
        XCTAssertEqual(req.sessionId, "abc")
        XCTAssertEqual(req.account, "work")
        XCTAssertEqual(req.target, .cmux)
        // Confirming the sheet performs the cmux launch with --resume.
        await state.confirmLaunch(req)
        XCTAssertNil(state.launchRequest)
        let newCalls = runner.calls(startingWith: "new-workspace")
        XCTAssertEqual(newCalls.count, 1)
        let args = newCalls[0].args
        let commandIndex = try XCTUnwrap(args.firstIndex(of: "--command"))
        XCTAssertTrue(args[commandIndex + 1].contains("--resume 'abc'"), args[commandIndex + 1])
    }

    // MARK: - beginNew (New Claude opens the launch sheet)

    func testBeginNewPresentsSheetSeededFromProjectDefaults() async throws {
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner)
        state.config.accounts = [AccountConfig(name: "work", configDir: "/tmp/grove-work")]
        state.config.projects = [ProjectConfig(name: "demo", path: "/ws",
                                               defaultModel: "opus", defaultEffort: "high")]
        let account = state.config.accounts[0]

        state.beginNew(cwd: "/ws/feature-a", title: "feature-a", account: account)

        // No process is spawned — only the sheet is presented.
        XCTAssertTrue(runner.calls(startingWith: "new-workspace").isEmpty)
        let req = try XCTUnwrap(state.launchRequest)
        XCTAssertNil(req.sessionId)                 // fresh session, not a resume
        XCTAssertEqual(req.cwd, "/ws/feature-a")
        XCTAssertEqual(req.title, "feature-a")
        XCTAssertEqual(req.account, "work")
        XCTAssertEqual(req.model, "opus")           // seeded from the owning project
        XCTAssertEqual(req.effort, "high")
        XCTAssertEqual(req.target, .cmux)
    }

    // MARK: - Per-session config (gear) + skip-permissions override

    /// The gear seeds the sheet to RESUME the session, carrying the project's
    /// skip-permissions default and recording the session's origin account.
    func testBeginConfigureSeedsResumeWithProjectSkipPermissions() async throws {
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner)
        state.config.accounts = [AccountConfig(name: "work", configDir: "/tmp/grove-work")]
        var project = ProjectConfig(name: "demo", path: "/ws")
        project.dangerouslySkipPermissions = true
        state.config.projects = [project]

        let session = ClaudeSession(id: "s9", cwd: "/ws/feat", title: "Feat",
                                    lastActivity: Date(), accountName: "work", gitBranch: nil)
        state.beginConfigure(session: session)

        let req = try XCTUnwrap(state.launchRequest)
        XCTAssertEqual(req.sessionId, "s9")              // resume, not new
        XCTAssertEqual(req.account, "work")
        XCTAssertEqual(req.originAccount, "work")        // origin recorded for cross-account
        XCTAssertTrue(req.skipPermissions)               // seeded from project default
        XCTAssertTrue(runner.calls(startingWith: "new-workspace").isEmpty)  // nothing spawned yet
    }

    /// The per-launch toggle WINS over the project default in BOTH directions:
    /// ON when the project is off, and OFF when the project is on.
    func testConfirmLaunchHonorsPerLaunchSkipPermissionsOverride() async throws {
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner)
        state.config.accounts = [AccountConfig(name: "default", configDir: "/tmp/x")]
        // Project default OFF, but the sheet turns it ON for this one launch.
        state.config.projects = [ProjectConfig(name: "p", path: "/ws")]
        var on = LaunchRequest(sessionId: nil, cwd: "/ws/a", title: "a", account: "default")
        on.skipPermissions = true
        await state.confirmLaunch(on)
        let onCmd = try cmuxCommand(runner)
        XCTAssertTrue(onCmd.contains("--dangerously-skip-permissions"), onCmd)

        // Project default ON, but the sheet turns it OFF — override must win.
        let runner2 = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state2 = makeState(runner2)
        state2.config.accounts = [AccountConfig(name: "default", configDir: "/tmp/x")]
        var proj = ProjectConfig(name: "p", path: "/ws")
        proj.dangerouslySkipPermissions = true
        state2.config.projects = [proj]
        var off = LaunchRequest(sessionId: nil, cwd: "/ws/a", title: "a", account: "default")
        off.skipPermissions = false
        await state2.confirmLaunch(off)
        let offCmd = try cmuxCommand(runner2)
        XCTAssertFalse(offCmd.contains("--dangerously-skip-permissions"), offCmd)
    }

    /// Extracts the cmux `--command` string from the first new-workspace call.
    private func cmuxCommand(_ runner: ScriptedRunner) throws -> String {
        let call = try XCTUnwrap(runner.calls(startingWith: "new-workspace").first)
        let i = try XCTUnwrap(call.args.firstIndex(of: "--command"))
        return call.args[i + 1]
    }

    // MARK: - refreshSessionIndex

    func testRefreshSessionIndexPopulatesRecentSessionsPerProject() async throws {
        let configDir = try FixtureLite.tempDir("session-index-claude")
        let projectRoot = "/Users/x/Projects/demo"
        let cwd = projectRoot + "/ws-a"
        let dir = configDir.appendingPathComponent("projects")
            .appendingPathComponent(ClaudeService.mangle(cwd))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","cwd":"\#(cwd)","sessionId":"sess-1","gitBranch":"main"}"#,
            #"{"type":"ai-title","aiTitle":"Demo work"}"#,
        ]
        try lines.joined(separator: "\n")
            .write(to: dir.appendingPathComponent("sess-1.jsonl"), atomically: true, encoding: .utf8)

        let state = makeState(ScriptedRunner(responses: ["ping": .ok("PONG")]))
        state.config.accounts = [AccountConfig(name: "default", configDir: configDir.path)]
        let project = ProjectConfig(name: "demo", path: projectRoot)
        state.config.projects = [project]
        // Empty cmux hook map (point at a nonexistent file, not the real one).
        state.cmuxHookFile = configDir.appendingPathComponent("no-hook.json").path

        await state.refreshSessionIndex()

        let rows = try XCTUnwrap(state.recentSessionsByProject[project.id])
        XCTAssertEqual(rows.map(\.sessionId), ["sess-1"])
        XCTAssertEqual(rows.first?.title, "Demo work")
        XCTAssertEqual(rows.first?.status, .closed)     // no live process in the fixture
        XCTAssertNil(rows.first?.cmuxWorkspaceId)
    }
}
