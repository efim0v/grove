import Foundation
import os

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

/// Thread-safe one-way boolean that tells the pipe readers to stop and return
/// what they have. Same pattern as `TimeoutFlag`, set from a different place.
/// Internal, not private, so `drainPipe` can be exercised directly.
final class AbandonFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Every failure below truncates the output silently — the caller still sees a
/// clean exit code — so each one says so here.
private let processRunnerLog = Logger(subsystem: "dev.artemefimov.brow", category: "ProcessRunner")

/// Reads one pipe's read end to EOF — or until `abandon` is set — and returns
/// what it collected.
///
/// `poll(2)` with a 100 ms timeout is what makes the read abandonable: the loop
/// is never parked in the kernel for longer than that, so the flag is honoured
/// within 100 ms no matter how long a writer keeps the pipe open. The handle is
/// closed here, on the same thread that reads it, so no one can pull the file
/// descriptor out from under an in-flight `read(2)` (a closed fd number is
/// reused immediately, and reading the wrong file is worse than reading late).
///
/// Every exit that is not EOF returns a SHORT read that the caller cannot tell
/// apart from complete output, so all of them are logged with the byte count
/// kept: without that, truncation is invisible.
func drainPipe(
    _ handle: FileHandle, stream: String, command: String, abandon: AbandonFlag
) -> Data {
    let fd = handle.fileDescriptor
    var collected = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    loop: while true {
        if abandon.isSet() {
            processRunnerLog.error(
                """
                \(stream, privacy: .public) drain abandoned after \
                \(ProcessRunner.drainGrace, format: .fixed(precision: 0), privacy: .public)s \
                grace — a writer still holds the pipe; '\(command, privacy: .public)' \
                output truncated at \(collected.count, privacy: .public) bytes
                """
            )
            break loop
        }

        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 100)
        if ready < 0 {
            let code = errno
            if code == EINTR { continue }
            processRunnerLog.error(
                """
                poll failed on the \(stream, privacy: .public) pipe of \
                '\(command, privacy: .public)': errno \(code, privacy: .public) \
                (\(String(cString: strerror(code)), privacy: .public)); output truncated at \
                \(collected.count, privacy: .public) bytes
                """
            )
            break loop                             // poll is broken; stop reading.
        }
        if ready == 0 { continue }                 // Idle: re-check the abandon flag.

        let count = buffer.withUnsafeMutableBytes { raw in
            read(fd, raw.baseAddress, raw.count)
        }
        switch count {
        case 1...:
            collected.append(contentsOf: buffer[0..<count])
        case 0:
            break loop                             // EOF: the last writer closed.
        default:
            let code = errno
            if code == EINTR || code == EAGAIN { continue }
            processRunnerLog.error(
                """
                read failed on the \(stream, privacy: .public) pipe of \
                '\(command, privacy: .public)': errno \(code, privacy: .public) \
                (\(String(cString: strerror(code)), privacy: .public)); output truncated at \
                \(collected.count, privacy: .public) bytes
                """
            )
            break loop                             // Read error; keep what we have.
        }
    }

    // One last NON-BLOCKING sweep before the descriptor goes. Every exit above can
    // leave bytes already sitting in the kernel pipe buffer, and the abandon check at
    // the top of the loop runs BEFORE the first poll: a reader task that has not been
    // scheduled at all by the time the 2 s grace expires (cooperative-pool saturation
    // under a wide fan-out — `WorkspaceService` starts an unbounded group of 300 s hook
    // processes) otherwise returns an EMPTY Data for a child whose output has been
    // waiting in the pipe since long before it exited, and the caller sees exit 0 with
    // no stdout: indistinguishable from a command that printed nothing. The old
    // `readDataToEndOfFile` was late in that situation; it was never empty.
    // Bounded, so a writer that keeps producing cannot turn the sweep into the loop we
    // just left: `poll` with a 0 ms timeout never waits, and 64 buffers is 4 MB.
    var recovered = 0
    sweep: for _ in 0..<64 {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { break sweep }
        let count = buffer.withUnsafeMutableBytes { raw in
            read(fd, raw.baseAddress, raw.count)
        }
        if count > 0 {
            collected.append(contentsOf: buffer[0..<count])
            recovered += count
            continue sweep
        }
        if count < 0 && errno == EINTR { continue sweep }
        break sweep                                // EOF, EAGAIN, or a read error.
    }
    if recovered > 0 {
        processRunnerLog.error(
            """
            recovered \(recovered, privacy: .public) buffered bytes from the \
            \(stream, privacy: .public) pipe of '\(command, privacy: .public)' \
            after the drain stopped
            """
        )
    }

    do {
        try handle.close()
    } catch {
        // Not a truncation — the bytes are already collected — but a leaked file
        // descriptor, which is fatal in aggregate for a process that runs forever.
        processRunnerLog.error(
            """
            closing the \(stream, privacy: .public) read end of \
            '\(command, privacy: .public)' failed: \
            \(error.localizedDescription, privacy: .public)
            """
        )
    }
    return collected
}

public struct ProcessRunner: CommandRunning, Sendable {
    /// How long the drain of stdout/stderr may outlive the child. A grandchild
    /// that inherited fd 1/2 can hold the pipes open long after the child exits;
    /// past this grace the readers are abandoned and `run` returns what it has.
    public static let drainGrace: TimeInterval = 2
    /// How long a child gets between SIGTERM and SIGKILL once the timeout fires. Named
    /// because it is part of every caller's real worst case, not just the timeout.
    public static let killGrace: TimeInterval = 0.5

    public init() {}

    /// Runs `executable` and returns its exit code and output.
    ///
    /// `run` returns within `timeout + drainGrace` plus scheduling slack in every
    /// case. The pipes are read by an abandonable `poll`/`read` loop rather than
    /// `readDataToEndOfFile`, which is unusable here on two counts: it waits for
    /// the *last* writer to close — any backgrounded grandchild of the child holds
    /// it open — and it cannot be interrupted, because closing the handle under a
    /// blocked `readDataToEndOfFile` raises an Objective-C exception rather than
    /// returning.
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
        let abandon = AbandonFlag()
        let stdoutTask = Task.detached {
            drainPipe(stdoutHandle, stream: "stdout", command: commandDescription, abandon: abandon)
        }
        let stderrTask = Task.detached {
            drainPipe(stderrHandle, stream: "stderr", command: commandDescription, abandon: abandon)
        }

        // Watchdog: SIGTERM at the deadline, escalate to SIGKILL 500ms later.
        let flag = TimeoutFlag()
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, process.isRunning else { return }
            flag.set()
            process.terminate()
            try? await Task.sleep(nanoseconds: UInt64(Self.killGrace * 1_000_000_000))
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        var exitCode: Int32 = -1
        for await code in exitStream { exitCode = code }
        watchdog.cancel()

        // The child is gone, but the write ends may not be: a grandchild that
        // inherited fd 1/2 outlives it. Give the readers `drainGrace` to reach EOF
        // on their own, then abandon them — they notice within one poll interval,
        // close their handles and return what they collected.
        let graceTimer = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(Self.drainGrace * 1_000_000_000))
            guard !Task.isCancelled else { return }
            abandon.set()
        }
        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value
        graceTimer.cancel()

        if flag.isSet() {
            throw GroveError.timeout(command: commandDescription)
        }

        // Lossy on purpose: an abandoned drain stops at an arbitrary byte offset and
        // can cut a multi-byte UTF-8 sequence in half, and `String(data:encoding:)`
        // answers nil for the whole stream when it does — a truncated tail must cost
        // one replacement character, never every byte the child wrote.
        return ProcessResult(
            exitCode: exitCode,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }
}
