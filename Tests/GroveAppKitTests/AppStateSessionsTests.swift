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
