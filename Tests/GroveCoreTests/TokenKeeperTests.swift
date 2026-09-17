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
        /// What the 1-based invocation returns — or throws. The default is the working
        /// CLI (exit 0, no output); overriding it lets the same double stand in for a
        /// watchdog timeout or a `claude` that is not on PATH.
        private let reply: @Sendable (Int) throws -> ProcessResult

        init(sideEffect: @escaping @Sendable (Int) -> Void = { _ in },
             reply: @escaping @Sendable (Int) throws -> ProcessResult = { _ in
                 ProcessResult(exitCode: 0, stdout: "", stderr: "")
             }) {
            self.sideEffect = sideEffect
            self.reply = reply
        }

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
            return try reply(call)
        }
    }

    /// A clock the test winds forward. The mutable instant lives in a box because a
    /// captured `var` in the `@Sendable` `now` closure is an error in Swift 6 mode.
    private final class Clock: @unchecked Sendable {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    /// Same trick for the network reachability the controller feeds in.
    private final class Flag: @unchecked Sendable {
        var value: Bool
        init(_ value: Bool) { self.value = value }
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
        let runner = FakeCLI(sideEffect: { _ in creds.expiry = self.t0.addingTimeInterval(8 * 3600) })
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
        let runner = FakeCLI(sideEffect: { call in
            if call == 2 { creds.expiry = self.t0.addingTimeInterval(8 * 3600) }
        })
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

    /// `CommandRunning` only throws on spawn/timeout, so a `doctor` that ran and
    /// disliked something reaches us as a plain non-zero exit and used to produce the
    /// generic "neither … refreshed the token". The exit code and the last stderr line
    /// have to travel. (127 — `claude` not on a GUI app's PATH — is no longer this
    /// case: see `testDoctorExit127IsCouldNotAttempt`.)
    func testNonZeroExitAndStderrReachTheFailureReason() async {
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(60)
        let runner = MockRunner(results: [ProcessResult(exitCode: 1, stdout: "",
                                                        stderr: "Invalid API key · Please run /login")])
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "claude",
                                 allowPromptFallback: { false }, now: { self.t0 })
        let out = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(out, .failed("claude doctor did not refresh the token (doctor exit 1: Invalid API key · Please run /login)"))
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

    /// The breaker must not outlive the trouble. `succeed` runs only when THIS keeper
    /// moved the expiry, and `ensureFresh` returns `.fresh` before it, so an account
    /// refreshed OUT OF BAND — Claude Code itself, a `claude` run in a terminal, a new
    /// sign-in — used to keep its failure count forever; and because the count is
    /// persisted, "forever" survived every relaunch: `-p` stayed dropped and the retry
    /// gap stayed at hours for an account that had been healthy for weeks.
    func testTokenObservedFreshResetsTheBreakerAndPersistsTheReset() async throws {
        let dir = try Fixture.tempDir("keeper-reset").path
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(60)
        let runner = FakeCLI()                        // nothing this keeper runs moves the expiry
        let clock = Clock(t0)
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { true }, now: { clock.date }, stateDirectory: dir)
        _ = await keeper.ensureFresh(configDir: "/d")                       // attempt 1
        clock.date = t0.addingTimeInterval(31 * 60)
        _ = await keeper.ensureFresh(configDir: "/d")                       // attempt 2
        clock.date = t0.addingTimeInterval(92 * 60)
        _ = await keeper.ensureFresh(configDir: "/d")                       // attempt 3 → -p is spent
        XCTAssertEqual(runner.invocations.filter { $0.args.first == "-p" }.count, 3)

        // The CLI (or Claude Code) refreshes the token elsewhere; Brow only observes it.
        clock.date = t0.addingTimeInterval(100 * 60)
        creds.expiry = clock.date.addingTimeInterval(8 * 3600)
        let observed = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(observed, .fresh)
        let state = try XCTUnwrap(FileManager.default.contents(atPath: dir + "/token-attempts.json"))
        XCTAssertEqual(try JSONDecoder().decode([String: TokenKeeper.Attempt].self, from: state)["/d"]?.failures, 0,
                       "the reset is persisted, not just held in memory until the next relaunch")

        // …and the next expiry is handled like any other account's: doctor runs, and
        // the `-p` leg is back on the table.
        clock.date = t0.addingTimeInterval(9 * 3600)
        creds.expiry = clock.date.addingTimeInterval(60)
        let out = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(runner.invocations.suffix(2).map(\.args),
                       [["doctor"], ["-p", ".", "--model", "haiku", "--max-turns", "1"]],
                       "doctor runs again and -p is no longer gated by the old failures")
        XCTAssertEqual(out, .failed("neither claude doctor nor claude -p refreshed the token"))
    }

    /// The gate has to survive the update that added `Attempt.forced`: every installed
    /// copy's `token-attempts.json` was written without that key, and the synthesised
    /// decoder throws `keyNotFound` on it — which would drop every account's floor and
    /// failure count on the first launch after the update.
    func testAttemptStateWrittenBeforeForcedExistedStillDecodes() throws {
        let legacy = Data(#"{"/d":{"at":721000000,"failures":2}}"#.utf8)
        let decoded = try JSONDecoder().decode([String: TokenKeeper.Attempt].self, from: legacy)
        XCTAssertEqual(decoded["/d"], TokenKeeper.Attempt(at: Date(timeIntervalSinceReferenceDate: 721_000_000),
                                                          failures: 2, forced: false))
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

    // MARK: - the network, the CLI that never ran, and the 401

    /// A network that is down is not evidence about the account, so it must not cost
    /// the account its one attempt per 30 min: no CLI is spawned, nothing is recorded,
    /// and the first cycle back online refreshes at once instead of waiting out a gate
    /// nothing earned. (This is the "offline attempts poison the breaker" bug.)
    func testOfflineSkipsWithoutConsumingTheFloor() async {
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(60)
        let runner = FakeCLI()
        let online = Flag(false)
        let clock = Clock(t0)
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { false }, isOnline: { online.value },
                                 now: { clock.date })
        let offline = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(offline, .skippedOffline)
        XCTAssertTrue(runner.invocations.isEmpty, "nothing is spawned while the network is down")

        online.value = true
        clock.date = t0.addingTimeInterval(5)     // five seconds — nowhere near the 30 min floor
        _ = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(runner.invocations.map(\.args), [["doctor"]],
                       "the offline cycle left no floor to wait out")
    }

    /// A `doctor` the watchdog had to kill never produced evidence about the token: the
    /// attempt record is rolled back (floor untouched), the breaker does not count it,
    /// and `-p` — which spends the account's limit and starts its 5-hour window — is not
    /// tried, because a timeout is far likelier to be the network than the token.
    func testDoctorTimeoutIsCouldNotAttemptAndDoesNotCountOrTryPrompt() async throws {
        let dir = try Fixture.tempDir("keeper-timeout").path
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(60)
        let runner = FakeCLI(reply: { _ in throw GroveError.timeout(command: "claude doctor") })
        let clock = Clock(t0)
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { true }, now: { clock.date }, stateDirectory: dir)
        let out = await keeper.ensureFresh(configDir: "/d")
        guard case .couldNotAttempt(let reason) = out else { return XCTFail("\(out)") }
        XCTAssertTrue(reason.contains("timed out"), reason)
        XCTAssertEqual(runner.invocations.map(\.args), [["doctor"]], "no -p after a doctor that never ran")

        let state = try XCTUnwrap(FileManager.default.contents(atPath: dir + "/token-attempts.json"))
        XCTAssertNil(try JSONDecoder().decode([String: TokenKeeper.Attempt].self, from: state)["/d"],
                     "the attempt is unrecorded, not merely uncounted")

        clock.date = t0.addingTimeInterval(60)    // one minute later, deep inside the floor
        _ = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(runner.invocations.map(\.args), [["doctor"], ["doctor"]],
                       "the next cycle tries again instead of sitting out 30 min")
    }

    /// 127 is the shell's "command not found": a wrong "Path to claude", or a GUI app's
    /// PATH without the CLI on it. The binary never ran, so there is nothing to count
    /// and nothing for `-p` to improve on — and the reason has to name what happened.
    func testDoctorExit127IsCouldNotAttempt() async {
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(60)
        let runner = FakeCLI(reply: { _ in
            ProcessResult(exitCode: 127, stdout: "", stderr: "env: claude: No such file or directory")
        })
        let clock = Clock(t0)
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "claude",
                                 allowPromptFallback: { true }, now: { clock.date })
        let out = await keeper.ensureFresh(configDir: "/d")
        guard case .couldNotAttempt(let reason) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(reason, "doctor exit 127: env: claude: No such file or directory")
        XCTAssertEqual(runner.invocations.map(\.args), [["doctor"]], "no -p on a CLI that is not there")

        clock.date = t0.addingTimeInterval(60)
        _ = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(runner.invocations.count, 2, "a CLI that never ran consumed no floor")
    }

    /// A 401 is the authoritative answer about a token, and it outranks both gates:
    /// `expiresAt` can claim hours of life that the server has already revoked, and the
    /// attempt floor would sit on the fix for half an hour. The bypass is ONCE, though —
    /// the attempt it forces holds the floor against the next rejection, or a rejected
    /// account would be handed a `doctor` on every cycle.
    func testAuthRejectedBypassesThresholdAndFloor() async throws {
        let dir = try Fixture.tempDir("keeper-401").path
        // Five hours of life and an attempt one minute old: both gates would normally
        // return before anything ran.
        try JSONEncoder().encode(["/d": TokenKeeper.Attempt(at: t0.addingTimeInterval(-60), failures: 0)])
            .write(to: URL(fileURLWithPath: dir + "/token-attempts.json"))
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(5 * 3600)
        let runner = FakeCLI()
        let clock = Clock(t0)
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { false }, now: { clock.date }, stateDirectory: dir)
        let forced = await keeper.ensureFresh(configDir: "/d", authRejected: true)
        XCTAssertEqual(forced, .failed("claude doctor did not refresh the token"))
        XCTAssertEqual(runner.invocations.map(\.args), [["doctor"]],
                       "a rejected token is refreshed even with 5 h of nominal life and a fresh attempt")

        clock.date = t0.addingTimeInterval(60)
        let second = await keeper.ensureFresh(configDir: "/d", authRejected: true)
        XCTAssertEqual(second, .skippedRateLimited, "the bypass is once; the attempt it made holds the floor")
        XCTAssertEqual(runner.invocations.count, 1)
    }

    /// The rejection episode does NOT end because `expiresAt` says the token is fine —
    /// that is the very signal `authRejected` exists to distrust, since a server-revoked
    /// token still carries hours of nominal life. So the keeper's own proactive cycle,
    /// which takes the "still fresh" shortcut, must leave the spent bypass spent; only a
    /// refresh that verifiably moved the expiry re-arms it. Otherwise every proactive
    /// tick between two rejections hands the next 401 a free `doctor`, forever.
    func testObservedFreshDoesNotReopenTheAuthRejectedBypass() async throws {
        let dir = try Fixture.tempDir("keeper-401-episode").path
        // Revoked by the server, but with 5 h of life on the record — the shape that
        // makes `expiresAt` worthless as evidence.
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(5 * 3600)
        let runner = FakeCLI()                    // doctor runs and fixes nothing
        let clock = Clock(t0)
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { false }, now: { clock.date }, stateDirectory: dir)
        let first = await keeper.ensureFresh(configDir: "/d", authRejected: true)
        XCTAssertEqual(first, .failed("claude doctor did not refresh the token"))
        XCTAssertEqual(runner.invocations.count, 1, "the rejection spends the bypass")

        clock.date = t0.addingTimeInterval(60)
        let proactive = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(proactive, .fresh, "the proactive cycle still believes the expiry — that is the point")

        clock.date = t0.addingTimeInterval(120)
        let next = await keeper.ensureFresh(configDir: "/d", authRejected: true)
        XCTAssertEqual(next, .skippedRateLimited, "the bypass stays spent across an observed-fresh cycle")
        XCTAssertEqual(runner.invocations.count, 1, "one doctor per episode, not one per rejection")
    }

    /// The other side of that: a refresh this keeper WATCHED land is real evidence, so it
    /// ends the episode and re-arms the bypass. A 401 on the brand-new token is a new
    /// episode and gets its own immediate `doctor`, floor or no floor.
    func testARefreshThatLandedReArmsTheAuthRejectedBypass() async throws {
        let dir = try Fixture.tempDir("keeper-401-rearm").path
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(5 * 3600)
        let clock = Clock(t0)
        // The first doctor really moves the expiry; the second does not.
        let runner = FakeCLI(sideEffect: { call in
            if call == 1 { creds.expiry = self.t0.addingTimeInterval(9 * 3600) }
        })
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { false }, now: { clock.date }, stateDirectory: dir)
        let first = await keeper.ensureFresh(configDir: "/d", authRejected: true)
        XCTAssertEqual(first, .refreshedByDoctor)

        clock.date = t0.addingTimeInterval(60)
        let next = await keeper.ensureFresh(configDir: "/d", authRejected: true)
        XCTAssertEqual(next, .failed("claude doctor did not refresh the token"),
                       "a 401 on a token the CLI just minted is a new episode, not the tail of the old one")
        XCTAssertEqual(runner.invocations.count, 2, "the landed refresh re-armed the bypass")
    }

    /// The other half of the floor rule, pinned so the could-not-attempt rollback can
    /// never widen into it: a `doctor` and a `-p` that BOTH ran and verifiably did not
    /// move the expiry are real evidence — they consume the floor and count toward the
    /// breaker, exactly as before.
    func testRanButUnchangedStillCounts() async throws {
        let dir = try Fixture.tempDir("keeper-counts").path
        let creds = MovableCreds(); creds.expiry = t0.addingTimeInterval(60)
        let runner = FakeCLI()                    // both legs run, neither moves the expiry
        let keeper = TokenKeeper(runner: runner, credentials: creds, claudePath: "/x/claude",
                                 allowPromptFallback: { true }, now: { self.t0 }, stateDirectory: dir)
        let out = await keeper.ensureFresh(configDir: "/d")
        XCTAssertEqual(out, .failed("neither claude doctor nor claude -p refreshed the token"))
        XCTAssertEqual(runner.invocations.map(\.args),
                       [["doctor"], ["-p", ".", "--model", "haiku", "--max-turns", "1"]])
        let state = try XCTUnwrap(FileManager.default.contents(atPath: dir + "/token-attempts.json"))
        let attempt = try XCTUnwrap(try JSONDecoder().decode([String: TokenKeeper.Attempt].self, from: state)["/d"])
        XCTAssertEqual(attempt.failures, 1)
        XCTAssertEqual(attempt.at, t0, "the attempt stands: the floor it started is real")
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
