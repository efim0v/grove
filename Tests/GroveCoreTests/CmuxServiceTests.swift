import XCTest
@testable import GroveCore

final class CmuxServiceTests: XCTestCase {

    private func ok(_ stdout: String) -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }

    private func failed(_ code: Int32 = 1) -> ProcessResult {
        ProcessResult(exitCode: code, stdout: "", stderr: "no socket")
    }

    /// The only signal the cmux CLI emits when the server hangs up on a
    /// denied peer (it never reads the server's ERROR line).
    private func brokenPipe() -> ProcessResult {
        ProcessResult(exitCode: 1, stdout: "",
                      stderr: "Error: Failed to write to socket (Broken pipe, errno 32)\n")
    }

    private static let denialLine =
        "ERROR: Access denied — only processes started inside cmux can connect"

    /// Hermetic service: socket denial probe and cmux.json password lookup
    /// are stubbed so unit tests never touch the real machine state.
    private func makeCmux(_ runner: MockRunner,
                          path: String = "/opt/cmux/bin/cmux",
                          greeting: String? = nil) -> CmuxService {
        CmuxService(runner: runner, cmuxPath: path,
                    configFile: "/nonexistent/grove-tests/cmux.json",
                    socketGreeting: { _ in greeting })
    }

    // MARK: ping

    func testPingReturnsTrueOnPong() async {
        let mock = MockRunner(results: [ok("PONG\n")])
        let cmux = makeCmux(mock)
        let alive = await cmux.ping()
        XCTAssertTrue(alive)
        XCTAssertEqual(mock.invocations.count, 1)
        XCTAssertEqual(mock.invocations[0].args, ["ping"])
    }

    func testPingReturnsFalseOnOtherOutput() async {
        let mock = MockRunner(results: [ok("NOPE")])
        let cmux = makeCmux(mock)
        let alive = await cmux.ping()
        XCTAssertFalse(alive)
    }

    func testPingReturnsFalseOnNonZeroExit() async {
        let mock = MockRunner(results: [failed()])
        let cmux = makeCmux(mock)
        let alive = await cmux.ping()
        XCTAssertFalse(alive)
    }

    // MARK: listWorkspaces

    /// Real cmux (0.64.4) wraps the workspace list in an envelope object.
    func testListWorkspacesDecodesEnvelopeJSON() async throws {
        let json = """
        {
          "window_id" : "B87E5902-D79A-4F07-9CBB-13631DC98AB7",
          "window_ref" : "window:1",
          "workspaces" : [
            {"id":"ws-1","title":"alpha","current_directory":"/Users/t/Workspaces/p/alpha",
             "index":0,"pinned":false,"ref":"workspace:15","selected":false,
             "custom_color":null,"description":null,"listening_ports":[]},
            {"id":"ws-2","title":"other","current_directory":"/tmp/elsewhere",
             "index":1,"pinned":false,"ref":"workspace:10","selected":true,
             "custom_color":null,"description":null,"listening_ports":[]}
          ]
        }
        """
        let mock = MockRunner(results: [ok(json)])
        let cmux = makeCmux(mock)
        let list = try await cmux.listWorkspaces()
        XCTAssertEqual(list, [
            CmuxWorkspace(id: "ws-1", title: "alpha", currentDirectory: "/Users/t/Workspaces/p/alpha"),
            CmuxWorkspace(id: "ws-2", title: "other", currentDirectory: "/tmp/elsewhere"),
        ])
        XCTAssertEqual(mock.invocations.count, 1)
        XCTAssertEqual(mock.invocations[0].args, ["rpc", "workspace.list", "{}"])
    }

    /// Older/newer cmux builds that emit a bare top-level array must keep working.
    func testListWorkspacesFallsBackToBareArrayJSON() async throws {
        let json = """
        [{"id":"ws-1","title":"alpha","current_directory":"/Users/t/Workspaces/p/alpha"},
         {"id":"ws-2","title":"other","current_directory":"/tmp/elsewhere"}]
        """
        let mock = MockRunner(results: [ok(json)])
        let cmux = makeCmux(mock)
        let list = try await cmux.listWorkspaces()
        XCTAssertEqual(list, [
            CmuxWorkspace(id: "ws-1", title: "alpha", currentDirectory: "/Users/t/Workspaces/p/alpha"),
            CmuxWorkspace(id: "ws-2", title: "other", currentDirectory: "/tmp/elsewhere"),
        ])
        XCTAssertEqual(mock.invocations.count, 1)
        XCTAssertEqual(mock.invocations[0].args, ["rpc", "workspace.list", "{}"])
    }

    func testListWorkspacesThrowsOnUnparseableJSON() async {
        let mock = MockRunner(results: [ok("not json at all")])
        let cmux = makeCmux(mock)
        do {
            _ = try await cmux.listWorkspaces()
            XCTFail("expected listWorkspaces to throw")
        } catch {
            XCTAssertTrue("\(error)".contains("unparseable"), "unexpected error: \(error)")
        }
    }

    // MARK: newWorkspace

    func testNewWorkspaceBuildsExactArgsAndOpensAppWhenFocused() async throws {
        let mock = MockRunner(results: [ok(""), ok("")])
        let cmux = makeCmux(mock)
        try await cmux.newWorkspace(name: "alpha", cwd: "/tmp/ws/alpha", command: "claude", focus: true)
        XCTAssertEqual(mock.invocations.count, 2)
        XCTAssertEqual(mock.invocations[0].executable, "/opt/cmux/bin/cmux")
        XCTAssertEqual(mock.invocations[0].args,
                       ["new-workspace", "--name", "alpha", "--cwd", "/tmp/ws/alpha",
                        "--command", "claude", "--focus", "true"])
        // cmux constrains focus-stealing: "--focus true" must be followed by app activation.
        XCTAssertEqual(mock.invocations[1].executable, "/usr/bin/open")
        XCTAssertEqual(mock.invocations[1].args, ["-b", "com.cmuxterm.app"])
    }

    func testNewWorkspaceOmitsCommandWhenNil() async throws {
        let mock = MockRunner(results: [ok(""), ok("")])
        let cmux = makeCmux(mock)
        try await cmux.newWorkspace(name: "alpha", cwd: "/tmp/ws/alpha", command: nil, focus: true)
        XCTAssertEqual(mock.invocations.count, 2)
        XCTAssertEqual(mock.invocations[0].args,
                       ["new-workspace", "--name", "alpha", "--cwd", "/tmp/ws/alpha", "--focus", "true"])
        XCTAssertEqual(mock.invocations[1].executable, "/usr/bin/open")
        XCTAssertEqual(mock.invocations[1].args, ["-b", "com.cmuxterm.app"])
    }

    func testNewWorkspaceDoesNotOpenAppWhenNotFocused() async throws {
        let mock = MockRunner(results: [ok("")])
        let cmux = makeCmux(mock)
        try await cmux.newWorkspace(name: "alpha", cwd: "/tmp/ws/alpha", command: "claude", focus: false)
        XCTAssertEqual(mock.invocations.count, 1)
        XCTAssertEqual(mock.invocations[0].executable, "/opt/cmux/bin/cmux")
        XCTAssertEqual(mock.invocations[0].args,
                       ["new-workspace", "--name", "alpha", "--cwd", "/tmp/ws/alpha",
                        "--command", "claude", "--focus", "false"])
    }

    // MARK: selectWorkspace

    func testSelectWorkspaceSelectsThenOpensCmuxApp() async throws {
        let mock = MockRunner(results: [ok(""), ok("")])
        let cmux = makeCmux(mock)
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
        let cmux = makeCmux(mock)
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
        let cmux = makeCmux(mock, path: "/custom/place/cmux")
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
        let cmux = makeCmux(MockRunner(results: []))
        let map = cmux.claudeSessionWorkspaceMap(hookFile: file.path)
        XCTAssertEqual(map, ["sess-1": "ws-uuid-1", "sess-2": "ws-uuid-2"])
    }

    func testClaudeSessionWorkspaceMapMissingFileIsEmpty() {
        let cmux = makeCmux(MockRunner(results: []))
        XCTAssertEqual(cmux.claudeSessionWorkspaceMap(hookFile: "/nonexistent/hook.json"), [:])
    }

    // MARK: - closeWorkspace

    func testCloseWorkspaceBuildsExactArgs() async throws {
        let mock = MockRunner(results: [ok("")])
        let cmux = makeCmux(mock)
        try await cmux.closeWorkspace("ws-9")
        XCTAssertEqual(mock.invocations.count, 1)
        XCTAssertEqual(mock.invocations[0].args, ["close-workspace", "--workspace", "ws-9"])
    }

    // MARK: - socket access control (GUI-context denial regression, see CmuxProbe)
    //
    // cmux's server only accepts clients descended from cmux unless the user
    // allows external automation. Grove launched via LaunchServices is denied:
    // the server writes an ERROR line and hangs up, and the CLI reports only
    // "Broken pipe". These tests pin the actionable-error conversion.

    func testEnsureRunningFailsFastWithActionableErrorWhenServerDeniesPeer() async {
        let mock = MockRunner(results: [brokenPipe()])
        let cmux = makeCmux(mock, greeting: Self.denialLine)
        do {
            try await cmux.ensureRunning()
            XCTFail("expected denial error")
        } catch {
            let text = "\(error)"
            XCTAssertTrue(text.contains("Access denied"), "got: \(text)")
            XCTAssertTrue(text.contains("Socket control mode"), "got: \(text)")
        }
        // Fail fast: launching cmux cannot help (it IS running), so no
        // `open -b` and no 10s ping loop.
        XCTAssertEqual(mock.invocations.count, 1)
        XCTAssertEqual(mock.invocations[0].args, ["ping"])
    }

    func testListWorkspacesConvertsBrokenPipeToActionableDenialError() async {
        let mock = MockRunner(results: [brokenPipe()])
        let cmux = makeCmux(mock, greeting: Self.denialLine)
        do {
            _ = try await cmux.listWorkspaces()
            XCTFail("expected denial error")
        } catch {
            let text = "\(error)"
            XCTAssertTrue(text.contains("cmux unavailable"), "got: \(text)")
            XCTAssertTrue(text.contains("Access denied"), "got: \(text)")
        }
    }

    func testBrokenPipeWithoutDenialStaysProcessFailed() async {
        // greeting nil = the socket is silent/absent (cmux died mid-flight):
        // the original processFailed must survive untouched.
        let mock = MockRunner(results: [brokenPipe()])
        let cmux = makeCmux(mock, greeting: nil)
        do {
            _ = try await cmux.listWorkspaces()
            XCTFail("expected processFailed")
        } catch GroveError.processFailed(_, let exitCode, let stderr) {
            XCTAssertEqual(exitCode, 1)
            XCTAssertTrue(stderr.contains("Broken pipe"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - socket password forwarding (automation.socketPassword)

    func testPingForwardsSocketPasswordFromCmuxConfig() async throws {
        let dir = try Fixture.tempDir("cmux-config")
        let file = dir.appendingPathComponent("cmux.json")
        try #"{"automation": {"socketControlMode": "password", "socketPassword": "s3cret"}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let mock = MockRunner(results: [ok("PONG")])
        let cmux = CmuxService(runner: mock, cmuxPath: "/opt/cmux/bin/cmux",
                               configFile: file.path, socketGreeting: { _ in nil })
        _ = await cmux.ping()
        XCTAssertEqual(mock.invocations[0].env?["CMUX_SOCKET_PASSWORD"], "s3cret")
    }

    func testNoPasswordEnvWhenCmuxConfigHasNone() async {
        let mock = MockRunner(results: [ok("PONG")])
        let cmux = makeCmux(mock)
        _ = await cmux.ping()
        XCTAssertNil(mock.invocations[0].env)
    }

    // MARK: - control socket path resolution

    func testControlSocketPathPrefersEnvOverrides() {
        XCTAssertEqual(CmuxService.controlSocketPath(env: ["CMUX_SOCKET_PATH": "/x/y.sock"]),
                       "/x/y.sock")
        XCTAssertEqual(CmuxService.controlSocketPath(env: ["CMUX_SOCKET": "/legacy.sock"]),
                       "/legacy.sock")
        // Empty values (cmux exports CMUX_SOCKET="") fall through to the default.
        XCTAssertEqual(CmuxService.controlSocketPath(env: ["CMUX_SOCKET": ""]),
                       NSHomeDirectory() + "/Library/Application Support/cmux/cmux.sock")
    }

    // MARK: - readSocketGreeting against a real local unix socket

    func testReadSocketGreetingReadsImmediateErrorLine() throws {
        let path = "/tmp/grove-test-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { close(server) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, "bind failed errno=\(errno)")
        XCTAssertEqual(listen(server, 1), 0)
        let line = Self.denialLine
        let acceptor = Thread {
            let client = accept(server, nil, nil)
            guard client >= 0 else { return }
            let bytes = Array((line + "\n").utf8)
            _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            close(client)
        }
        acceptor.start()
        XCTAssertEqual(CmuxService.readSocketGreeting(path: path), line)
    }

    func testReadSocketGreetingNilWhenSocketAbsent() {
        XCTAssertNil(CmuxService.readSocketGreeting(path: "/nonexistent/grove/no.sock"))
    }
}
