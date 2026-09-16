import XCTest
@testable import GroveCore

final class TokenKeeperTests: XCTestCase {
    /// Credentials whose expiry the test moves to simulate the CLI refreshing the token.
    private final class MovableCreds: CredentialsReading, @unchecked Sendable {
        var expiry: Date?
        var invalidations = 0
        func token(configDir: String) -> ClaudeToken? {
            expiry.map { ClaudeToken(value: "t", expiresAt: $0) }
        }
        func invalidate(configDir: String) { invalidations += 1 }
    }

    /// A CommandRunning double that also plays the CLI's side effect on the Keychain.
    /// `sideEffect` runs with the 1-based invocation index AFTER that invocation is
    /// recorded and BEFORE `run` returns — i.e. exactly where the real CLI moves the
    /// expiry, so `TokenKeeper`'s re-read sees it without any polling or sleeping.
    /// Also records timeouts, which `MockRunner` does not.
    private final class FakeCLI: CommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(executable: String, args: [String], env: [String: String]?)] = []
        private var recordedTimeouts: [TimeInterval] = []
        private let sideEffect: @Sendable (Int) -> Void

        init(sideEffect: @escaping @Sendable (Int) -> Void = { _ in }) { self.sideEffect = sideEffect }

        var invocations: [(executable: String, args: [String], env: [String: String]?)] {
            lock.withLock { recorded }
        }
        var timeouts: [TimeInterval] { lock.withLock { recordedTimeouts } }

        func run(_ executable: String, _ args: [String], cwd: String?, env: [String: String]?,
                 timeout: TimeInterval) async throws -> ProcessResult {
            let call = lock.withLock {
                recorded.append((executable: executable, args: args, env: env))
                recordedTimeouts.append(timeout)
                return recorded.count
            }
            sideEffect(call)
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    /// A clock the test winds forward. The mutable instant lives in a box because a
    /// captured `var` in the `@Sendable` `now` closure is an error in Swift 6 mode.
    private final class Clock: @unchecked Sendable {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func ok() -> ProcessResult { ProcessResult(exitCode: 0, stdout: "", stderr: "") }

    func testTokenWithPlentyOfLifeIsLeftAlone() async {
        let runner = MockRunner(results: [])
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(3600)
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { true }, now: { self.t0 })
        let out = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(out, .fresh)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testDoctorRunsBelowThresholdAndSucceedsWhenExpiryMoves() async {
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(10 * 60)
        // The runner can't move the Keychain; emulate the CLI doing so as `doctor` runs,
        // which is the only moment that makes the post-doctor re-read see a new expiry.
        let runner = FakeCLI { _ in creds.expiry = self.t0.addingTimeInterval(8 * 3600) }
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { true }, now: { self.t0 })
        let out = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(out, .refreshedByDoctor)
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations[0].executable, "/x/claude")
        XCTAssertEqual(runner.invocations[0].args, ["doctor"])
        XCTAssertEqual(runner.invocations[0].env?["CLAUDE_CONFIG_DIR"], "/d")
        XCTAssertEqual(creds.invalidations, 1, "the cached token must be dropped so the re-read sees the new one")
    }

    func testExpiredTokenTriggers() async {
        let runner = MockRunner(results: [ok()])
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(-3600)
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { false }, now: { self.t0 })
        _ = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testUnreadableTokenSpawnsNothing() async {
        // No Keychain item, or the user has not answered the access prompt yet: neither
        // `doctor` nor `-p` can be verified, and `-p` would spend limit blindly.
        let runner = MockRunner(results: [ok(), ok()])
        let creds = MovableCreds(); creds.expiry = nil
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { true }, now: { self.t0 })
        let out = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(out, .failed("no readable token"))
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testFallbackToPromptWhenDoctorDidNotMoveExpiry() async {
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(60)
        // First re-read (after doctor) still shows the old expiry; second (after -p) shows a
        // new one — so the expiry moves only on the second invocation.
        let runner = FakeCLI { call in
            if call == 2 { creds.expiry = self.t0.addingTimeInterval(8 * 3600) }
        }
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { true }, now: { self.t0 })
        let out = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(out, .refreshedByPrompt)
        XCTAssertEqual(runner.invocations.map(\.args), [["doctor"], ["-p", ".", "--model", "haiku", "--max-turns", "1"]])
    }

    func testNoFallbackWhenSettingOff() async {
        let runner = MockRunner(results: [ok()])
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(60)
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { false }, now: { self.t0 })
        let out = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(out, .failed("claude doctor did not refresh the token"))
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testOneAttemptPerThirtyMinutesRegardlessOfOutcome() async {
        let runner = MockRunner(results: [ok()])
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(60)
        let clock = Clock(t0)
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { false }, now: { clock.date })
        _ = await keeper.ensureFresh(configDir: "/d")                  // fails
        clock.date = t0.addingTimeInterval(29 * 60)
        let second = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(second, .skippedRateLimited)
        XCTAssertEqual(runner.invocations.count, 1)
        clock.date = t0.addingTimeInterval(31 * 60)
        _ = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(runner.invocations.count, 2, "a new attempt is allowed after 30 min")
    }

    func testRunnerErrorMapsToFailed() async {
        struct Boom: CommandRunning {
            func run(_ executable: String, _ args: [String], cwd: String?, env: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
                throw GroveError.processFailed(command: "claude doctor", exitCode: 1, stderr: "timeout")
            }
        }
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(60)
        let keeper = TokenKeeper(runner: Boom(), credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { false }, now: { self.t0 })
        let out = await keeper.ensureFresh(configDir: "/d")
        if case .failed(let reason) = out { XCTAssertTrue(reason.contains("doctor")) } else { XCTFail("\(out)") }
    }

    func testTimeoutsMatchSpec() async {
        // Neither attempt moves the expiry, so both `doctor` and `-p` run.
        let runner = FakeCLI()
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(60)
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { true }, now: { self.t0 })
        _ = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(runner.timeouts, [90, 120])
    }
}
