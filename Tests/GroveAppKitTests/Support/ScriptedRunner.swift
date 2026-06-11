import Foundation
import GroveCore

/// CommandRunning double for cmux interactions: NOTHING is ever executed.
/// Responses are routed by the first argument of the call ("ping", "rpc",
/// "new-workspace", "select-workspace", "-b" for /usr/bin/open) so tests stay
/// robust against incidental extra calls; unrouted calls get `fallback`
/// (empty success by default). Every invocation is recorded for assertions.
final class ScriptedRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let args: [String]
    }

    private let lock = NSLock()
    private let responses: [String: ProcessResult]
    private let fallback: ProcessResult
    private var recorded: [Call] = []

    init(responses: [String: ProcessResult],
         fallback: ProcessResult = ProcessResult(exitCode: 0, stdout: "", stderr: "")) {
        self.responses = responses
        self.fallback = fallback
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func calls(startingWith subcommand: String) -> [Call] {
        calls.filter { $0.args.first == subcommand }
    }

    func run(_ executable: String, _ args: [String], cwd: String?, env: [String: String]?,
             timeout: TimeInterval) async throws -> ProcessResult {
        recordAndRespond(Call(executable: executable, args: args))
    }

    /// Synchronous so the NSLock is never used from an async frame.
    private func recordAndRespond(_ call: Call) -> ProcessResult {
        lock.lock(); defer { lock.unlock() }
        recorded.append(call)
        if let first = call.args.first, let response = responses[first] {
            return response
        }
        return fallback
    }
}

extension ProcessResult {
    static func ok(_ stdout: String = "") -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }

    static func fail(_ stderr: String = "boom", code: Int32 = 1) -> ProcessResult {
        ProcessResult(exitCode: code, stdout: "", stderr: stderr)
    }
}

/// A CmuxService that answers ping with PONG and lists zero workspaces —
/// the standard "cmux is up but empty" stub for scan-path tests.
func stubbedCmux(_ runner: ScriptedRunner? = nil) -> CmuxService {
    CmuxService(
        runner: runner ?? ScriptedRunner(responses: [
            "ping": .ok("PONG"),
            "rpc": .ok(#"{"workspaces": []}"#),
        ]),
        cmuxPath: "/grove-tests/stub/cmux")
}
