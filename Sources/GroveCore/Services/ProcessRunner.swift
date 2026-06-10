import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func run(
        _ executable: String, _ args: [String],
        cwd: String?, env: [String: String]?, timeout: TimeInterval
    ) async throws -> ProcessResult
}

public extension CommandRunning {
    /// Like run, but throws GroveError.processFailed when the exit code is non-zero.
    @discardableResult
    func runOK(
        _ executable: String, _ args: [String],
        cwd: String? = nil, env: [String: String]? = nil, timeout: TimeInterval = 10
    ) async throws -> ProcessResult {
        let result = try await run(executable, args, cwd: cwd, env: env, timeout: timeout)
        guard result.exitCode == 0 else {
            throw GroveError.processFailed(
                command: ([executable] + args).joined(separator: " "),
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return result
    }
}

/// Thread-safe one-way boolean set by the timeout watchdog.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

public struct ProcessRunner: CommandRunning, Sendable {
    public init() {}

    public func run(
        _ executable: String, _ args: [String],
        cwd: String? = nil, env: [String: String]? = nil, timeout: TimeInterval = 10
    ) async throws -> ProcessResult {
        let commandDescription = ([executable] + args).joined(separator: " ")

        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: expandTilde(executable))
            process.arguments = args
        } else {
            // Bare name: resolve through PATH via /usr/bin/env.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + args
        }
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: expandTilde(cwd), isDirectory: true)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if let env {
            environment.merge(env) { _, override in override }
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // Termination is observed via terminationHandler wrapped in an AsyncStream.
        // The handler is installed BEFORE run(), and AsyncStream buffers the yield,
        // so an exit can never be missed even if it happens before we iterate.
        let exitStream = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            throw GroveError.io("failed to launch '\(commandDescription)': \(error.localizedDescription)")
        }

        // Drain both pipes concurrently with the running child. Reading only after
        // exit would deadlock once a pipe's 64KB kernel buffer fills up.
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let stdoutTask = Task.detached { stdoutHandle.readDataToEndOfFile() }
        let stderrTask = Task.detached { stderrHandle.readDataToEndOfFile() }

        // Watchdog: SIGTERM at the deadline, escalate to SIGKILL 500ms later.
        let flag = TimeoutFlag()
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, process.isRunning else { return }
            flag.set()
            process.terminate()
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        var exitCode: Int32 = -1
        for await code in exitStream { exitCode = code }
        watchdog.cancel()

        if flag.isSet() {
            // Abandon the drain tasks; they finish on their own once the pipes hit EOF.
            throw GroveError.timeout(command: commandDescription)
        }

        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value
        return ProcessResult(
            exitCode: exitCode,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
