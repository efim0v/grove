import XCTest
@testable import GroveCore

final class TokenKeeperTests: XCTestCase {
    /// Credentials whose expiry the test moves to simulate the CLI refreshing the token.
    private final class MovableCreds: CredentialsReading, @unchecked Sendable {
        var expiry: Date?
        var invalidations = 0
        /// Stands in for "the Keychain prompt was denied / timed out between the two
        /// reads": the token was readable before `claude doctor` and is not after.
        var vanishOnInvalidate = false
        func token(configDir: String) -> ClaudeToken? {
            expiry.map { ClaudeToken(value: "t", expiresAt: $0) }
        }
        func invalidate(configDir: String) {
            invalidations += 1
            if vanishOnInvalidate { expiry = nil }
        }
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

    /// A token that became UNREADABLE after `claude doctor` is not the same as one
    /// whose expiry did not move: `-p` could not be verified either, and it spends the
    /// account's limit and starts its 5-hour window. It must not run.
    func testUnreadableAfterDoctorDoesNotSpawnPrompt() async {
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(60)
        creds.vanishOnInvalidate = true
        let runner = MockRunner(results: [ok(), ok()])
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { true }, now: { self.t0 })
        let out = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(out, .failed("token became unreadable after claude doctor"))
        XCTAssertEqual(runner.invocations.map(\.args), [["doctor"]], "no -p on a token we cannot verify")
    }

    /// `CommandRunning` only throws on spawn/timeout, so a `claude` that is not on a
    /// GUI app's PATH exits 127 twice and used to produce the generic "neither …
    /// refreshed the token". The exit code and the last stderr line have to travel.
    func testNonZeroExitAndStderrReachTheFailureReason() async {
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(60)
        let runner = MockRunner(results: [ProcessResult(exitCode: 127, stdout: "",
                                                        stderr: "env: claude: No such file or directory")])
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "claude",
                                 allowPromptFallback: { false }, now: { self.t0 })
        let out = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(out, .failed("claude doctor did not refresh the token (doctor exit 127: env: claude: No such file or directory)"))
    }

    /// The circuit breaker. `-p` costs limit and restarts the 5-hour window, so an
    /// account it cannot fix must stop being charged for it: the gap doubles from the
    /// spec's 30 min floor, and after three ineffective attempts `-p` is dropped for
    /// good while the free `doctor` keeps running.
    func testPromptIsAbandonedAfterThreeIneffectiveAttempts() async {
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(60)
        let runner = FakeCLI()                 // nothing ever moves the expiry
        let clock = Clock(t0)
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { true }, now: { clock.date })
        _ = await keeper.ensureFresh(configDir: "/d")                       // attempt 1
        clock.date = t0.addingTimeInterval(31 * 60)
        _ = await keeper.ensureFresh(configDir: "/d")                       // attempt 2 (30 min floor)
        clock.date = t0.addingTimeInterval(62 * 60)
        let tooSoon = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(tooSoon, .skippedRateLimited, "after two failures the gap has doubled to 60 min")
        clock.date = t0.addingTimeInterval(92 * 60)
        _ = await keeper.ensureFresh(configDir: "/d")                       // attempt 3
        clock.date = t0.addingTimeInterval(213 * 60)
        let fourth = await keeper.ensureFresh(configDir: "/d")              // attempt 4
        XCTAssertEqual(runner.invocations.filter { $0.args.first == "-p" }.count, 3,
                       "-p runs three times at most, never again")
        XCTAssertEqual(runner.invocations.last?.args, ["doctor"], "doctor is free and keeps running")
        XCTAssertEqual(fourth, .failed("sign in again"))
    }

    func testRetryIntervalDoublesFromThirtyMinutesAndIsCappedAtTwelveHours() {
        XCTAssertEqual(TokenKeeper.retryInterval(failures: 0), 30 * 60)
        XCTAssertEqual(TokenKeeper.retryInterval(failures: 1), 30 * 60, "the spec's 30 min floor survives")
        XCTAssertEqual(TokenKeeper.retryInterval(failures: 2), 60 * 60)
        XCTAssertEqual(TokenKeeper.retryInterval(failures: 3), 120 * 60)
        XCTAssertEqual(TokenKeeper.retryInterval(failures: 99), 12 * 3600)
    }

    /// Launch-at-login relaunches the process; an in-memory gate would hand every dead
    /// account a fresh `doctor` + `-p` on every relaunch.
    func testAttemptGateSurvivesARelaunch() async throws {
        let dir = try Fixture.tempDir("keeper-state").path
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(60)
        let first = MockRunner(results: [ok()])
        let keeper = TokenKeeper(runner: first, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { false }, now: { self.t0 }, stateDirectory: dir)
        _ = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(first.invocations.count, 1)

        let second = MockRunner(results: [ok()])
        let relaunched = TokenKeeper(runner: second, credentials: creds, claudePath: "/x/claude",
                                     allowPromptFallback: { false },
                                     now: { self.t0.addingTimeInterval(5 * 60) }, stateDirectory: dir)
        let afterRelaunch = await relaunched.ensureFresh(configDir: "/d")
        XCTAssertEqual(afterRelaunch, .skippedRateLimited)
        XCTAssertTrue(second.invocations.isEmpty, "the persisted gate still holds after a relaunch")
    }

    /// Settings › General can correct a wrong "Path to claude" at any time; the keeper
    /// reads the path per call, so the next cycle uses the corrected binary.
    func testClaudePathIsReadPerCall() async {
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(60)
        let runner = MockRunner(results: [ok(), ok()])
        let box = PathBox("/old/claude")
        let clock = Clock(t0)
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: { box.value },
                                 allowPromptFallback: { false }, now: { clock.date })
        _ = await keeper.ensureFresh(configDir: "/d")
        box.value = "/new/claude"
        clock.date = t0.addingTimeInterval(31 * 60)
        _ = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(runner.invocations.map(\.executable), ["/old/claude", "/new/claude"])
    }

    private final class PathBox: @unchecked Sendable {
        var value: String
        init(_ value: String) { self.value = value }
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
