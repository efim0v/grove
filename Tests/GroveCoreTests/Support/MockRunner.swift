import Foundation
@testable import GroveCore

/// Scripted CommandRunning double: records every invocation and replays
/// pre-baked ProcessResults in FIFO order. When the script is exhausted it
/// returns an empty success, so accidental extra calls fail assertions
/// (invocation counts / contents), not the whole test run.
final class MockRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [ProcessResult]
    private var recorded: [(executable: String, args: [String])] = []

    init(results: [ProcessResult]) {
        self.script = results
    }

    var invocations: [(executable: String, args: [String])] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func run(_ executable: String, _ args: [String], cwd: String?, env: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        lock.lock(); defer { lock.unlock() }
        recorded.append((executable: executable, args: args))
        guard !script.isEmpty else {
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        return script.removeFirst()
    }
}
