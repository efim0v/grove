import XCTest
@testable import GroveCore

final class CmuxServiceTests: XCTestCase {

    private func ok(_ stdout: String) -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }

    private func failed(_ code: Int32 = 1) -> ProcessResult {
        ProcessResult(exitCode: code, stdout: "", stderr: "no socket")
    }

    // MARK: ping

    func testPingReturnsTrueOnPong() async {
        let mock = MockRunner(results: [ok("PONG\n")])
        let cmux = CmuxService(runner: mock, cmuxPath: "/opt/cmux/bin/cmux")
        let alive = await cmux.ping()
        XCTAssertTrue(alive)
        XCTAssertEqual(mock.invocations.count, 1)
        XCTAssertEqual(mock.invocations[0].args, ["ping"])
    }

    func testPingReturnsFalseOnOtherOutput() async {
        let mock = MockRunner(results: [ok("NOPE")])
        let cmux = CmuxService(runner: mock, cmuxPath: "/opt/cmux/bin/cmux")
        let alive = await cmux.ping()
        XCTAssertFalse(alive)
    }

    func testPingReturnsFalseOnNonZeroExit() async {
        let mock = MockRunner(results: [failed()])
        let cmux = CmuxService(runner: mock, cmuxPath: "/opt/cmux/bin/cmux")
        let alive = await cmux.ping()
        XCTAssertFalse(alive)
    }

    // MARK: listWorkspaces

    func testListWorkspacesDecodesSnakeCaseJSON() async throws {
        let json = """
        [{"id":"ws-1","title":"alpha","current_directory":"/Users/t/Workspaces/p/alpha"},
         {"id":"ws-2","title":"other","current_directory":"/tmp/elsewhere"}]
        """
        let mock = MockRunner(results: [ok(json)])
        let cmux = CmuxService(runner: mock, cmuxPath: "/opt/cmux/bin/cmux")
        let list = try await cmux.listWorkspaces()
        XCTAssertEqual(list, [
            CmuxWorkspace(id: "ws-1", title: "alpha", currentDirectory: "/Users/t/Workspaces/p/alpha"),
            CmuxWorkspace(id: "ws-2", title: "other", currentDirectory: "/tmp/elsewhere"),
        ])
        XCTAssertEqual(mock.invocations.count, 1)
        XCTAssertEqual(mock.invocations[0].args, ["rpc", "workspace.list", "{}"])
    }

    // MARK: newWorkspace

    func testNewWorkspaceBuildsExactArgs() async throws {
        let mock = MockRunner(results: [ok("")])
        let cmux = CmuxService(runner: mock, cmuxPath: "/opt/cmux/bin/cmux")
        try await cmux.newWorkspace(name: "alpha", cwd: "/tmp/ws/alpha", command: "claude", focus: true)
        XCTAssertEqual(mock.invocations.count, 1)
        XCTAssertEqual(mock.invocations[0].executable, "/opt/cmux/bin/cmux")
        XCTAssertEqual(mock.invocations[0].args,
                       ["new-workspace", "--name", "alpha", "--cwd", "/tmp/ws/alpha",
                        "--command", "claude", "--focus", "true"])
    }

    func testNewWorkspaceOmitsCommandWhenNil() async throws {
        let mock = MockRunner(results: [ok("")])
        let cmux = CmuxService(runner: mock, cmuxPath: "/opt/cmux/bin/cmux")
        try await cmux.newWorkspace(name: "alpha", cwd: "/tmp/ws/alpha", command: nil, focus: true)
        XCTAssertEqual(mock.invocations.count, 1)
        XCTAssertEqual(mock.invocations[0].args,
                       ["new-workspace", "--name", "alpha", "--cwd", "/tmp/ws/alpha", "--focus", "true"])
    }

    // MARK: selectWorkspace

    func testSelectWorkspaceSelectsThenOpensCmuxApp() async throws {
        let mock = MockRunner(results: [ok(""), ok("")])
        let cmux = CmuxService(runner: mock, cmuxPath: "/opt/cmux/bin/cmux")
        try await cmux.selectWorkspace("ws-1")
        XCTAssertEqual(mock.invocations.count, 2)
        XCTAssertEqual(mock.invocations[0].executable, "/opt/cmux/bin/cmux")
        XCTAssertEqual(mock.invocations[0].args, ["select-workspace", "--workspace", "ws-1"])
        XCTAssertEqual(mock.invocations[1].executable, "/usr/bin/open")
        XCTAssertEqual(mock.invocations[1].args, ["-b", "com.cmuxterm.app"])
    }

    // MARK: ensureRunning

    func testEnsureRunningLaunchesAppWhenFirstPingFails() async throws {
        let mock = MockRunner(results: [failed(), ok(""), ok("PONG")])
        let cmux = CmuxService(runner: mock, cmuxPath: "/opt/cmux/bin/cmux")
        try await cmux.ensureRunning()
        XCTAssertEqual(mock.invocations.count, 3)
        XCTAssertEqual(mock.invocations[0].args, ["ping"])
        XCTAssertEqual(mock.invocations[1].executable, "/usr/bin/open")
        XCTAssertEqual(mock.invocations[1].args, ["-b", "com.cmuxterm.app"])
        XCTAssertEqual(mock.invocations[2].args, ["ping"])
    }

    // MARK: executable resolution

    func testExplicitCmuxPathUsedAsExecutable() async {
        let mock = MockRunner(results: [ok("PONG")])
        let cmux = CmuxService(runner: mock, cmuxPath: "/custom/place/cmux")
        _ = await cmux.ping()
        XCTAssertEqual(mock.invocations[0].executable, "/custom/place/cmux")
    }

    // MARK: - claude-hook-sessions.json map

    func testClaudeSessionWorkspaceMapParsesHookFile() throws {
        let dir = try Fixture.tempDir("cmux-hook")
        let file = dir.appendingPathComponent("claude-hook-sessions.json")
        let json = """
        {"sess-1": {"cwd": "/tmp/a", "pid": 1, "workspaceId": "ws-uuid-1"},
         "sess-2": {"cwd": "/tmp/b", "workspaceId": "ws-uuid-2"},
         "broken": "not-an-object"}
        """
        try json.write(to: file, atomically: true, encoding: .utf8)
        let cmux = CmuxService(runner: MockRunner(results: []), cmuxPath: "/opt/cmux/bin/cmux")
        let map = cmux.claudeSessionWorkspaceMap(hookFile: file.path)
        XCTAssertEqual(map, ["sess-1": "ws-uuid-1", "sess-2": "ws-uuid-2"])
    }

    func testClaudeSessionWorkspaceMapMissingFileIsEmpty() {
        let cmux = CmuxService(runner: MockRunner(results: []), cmuxPath: "/opt/cmux/bin/cmux")
        XCTAssertEqual(cmux.claudeSessionWorkspaceMap(hookFile: "/nonexistent/hook.json"), [:])
    }
}
