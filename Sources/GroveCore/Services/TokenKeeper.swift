import Foundation
import os

public enum TokenRefreshOutcome: Sendable, Equatable {
    /// More than `TokenKeeper.threshold` of life remained; nothing was run.
    case fresh
    /// An attempt ran less than the current retry interval ago; nothing was run.
    case skippedRateLimited
    /// The network is down. Nothing was run and nothing was recorded: the CLI could not
    /// have refreshed anything, so this must not cost the account its one attempt.
    case skippedOffline
    /// The CLI could not run at all — the spawn failed, the watchdog fired, or it exited
    /// 127. No evidence about the token, so the floor is not consumed, the breaker does
    /// not count it, and `-p` is not tried.
    case couldNotAttempt(String)
    case refreshedByDoctor
    case refreshedByPrompt
    case failed(String)
}

/// Keeps an idle account's OAuth access token alive by running the REAL Claude
/// Code CLI in that account's config dir — never by touching the refresh token
/// ourselves (the legal page forbids third parties from handling Claude.ai
/// credentials; the unmodified CLI is the sanctioned path).
///
/// Verified on Claude Code 2.1.273: `claude doctor` refreshes the Keychain token
/// with NO model call, so the account's 5-hour window stays unstarted. That is
/// an undocumented side effect, so a `claude -p` fallback (which does spend a
/// sliver of limit and starts the window) exists behind a user setting.
///
/// Success is judged by the ONLY thing that matters: did `expiresAt` move
/// forward. Exit codes are not trusted as success — but they ARE reported, and a
/// `claude` that never ran at all (exit 127, a failed spawn, a fired watchdog) is
/// `.couldNotAttempt`: it says so instead of hiding behind "neither … refreshed
/// the token", and it is charged neither the attempt floor nor the breaker.
public actor TokenKeeper {
    public static let threshold: TimeInterval = 30 * 60
    /// Floor between two attempts for one account — the spec's "one token-refresh
    /// attempt per account per 30 min". Consecutive ineffective attempts double it.
    public static let attemptInterval: TimeInterval = 30 * 60
    /// Ceiling for that doubling. Without it a permanently dead sign-in is retried
    /// 48 times a day forever.
    public static let maxAttemptInterval: TimeInterval = 12 * 3600
    /// After this many consecutive ineffective attempts the `-p` leg is dropped for
    /// good: `doctor` is free, `-p` spends the account's limit and starts its
    /// 5-hour window, and by now we know it does not help.
    public static let promptGiveUpAfter = 3
    static let doctorTimeout: TimeInterval = 90
    static let promptTimeout: TimeInterval = 120

    private static let log = Logger(subsystem: "dev.artemefimov.brow", category: "TokenKeeper")

    /// One account's attempt bookkeeping, persisted so relaunching (or launch-at-login)
    /// does not hand a dead account a fresh `doctor` + `-p` every time.
    struct Attempt: Codable, Sendable, Equatable {
        var at: Date
        var failures: Int
        /// This attempt was forced by a rejected token (`authRejected: true`). It is what
        /// makes that bypass happen ONCE: the next rejection sees it and obeys the floor
        /// like anyone else, so a permanently rejected account is not handed a `doctor`
        /// on every cycle. Persisted with the rest for the same reason the rest is — a
        /// relaunch must not reopen the bypass.
        var forced: Bool

        init(at: Date, failures: Int, forced: Bool = false) {
            self.at = at
            self.failures = failures
            self.forced = forced
        }

        /// Hand-written because the synthesised decoder throws `keyNotFound` on a
        /// `token-attempts.json` written before `forced` existed — which would discard
        /// every account's gate on the first launch after an update.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            at = try container.decode(Date.self, forKey: .at)
            failures = try container.decode(Int.self, forKey: .failures)
            forced = try container.decodeIfPresent(Bool.self, forKey: .forced) ?? false
        }
    }

    private let runner: CommandRunning
    private let credentials: CredentialsReading
    /// Read through a closure, not captured once: Settings › General can correct a
    /// wrong "Path to claude" at any time and the next cycle must use the new one.
    private let claudePath: @Sendable () -> String
    private let allowPromptFallback: @Sendable () -> Bool
    /// Network reachability, fed by the controller from `NWPathMonitor`. Read per call
    /// for the same reason `claudePath` is: the answer changes while the app runs.
    private let isOnline: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    /// nil → attempts live in memory only (tests, and any caller that wants no file).
    private let stateDirectory: String?
    private var attempts: [String: Attempt] = [:]
    private var loadedState = false

    public init(runner: CommandRunning, credentials: CredentialsReading,
                claudePath: @escaping @Sendable () -> String,
                allowPromptFallback: @escaping @Sendable () -> Bool,
                isOnline: @escaping @Sendable () -> Bool = { true },
                now: @escaping @Sendable () -> Date = { Date() },
                stateDirectory: String? = nil) {
        self.runner = runner
        self.credentials = credentials
        self.claudePath = claudePath
        self.allowPromptFallback = allowPromptFallback
        self.isOnline = isOnline
        self.now = now
        self.stateDirectory = stateDirectory
    }

    /// Fixed-path convenience (tests and any caller whose path cannot change).
    public init(runner: CommandRunning, credentials: CredentialsReading, claudePath: String,
                allowPromptFallback: @escaping @Sendable () -> Bool,
                isOnline: @escaping @Sendable () -> Bool = { true },
                now: @escaping @Sendable () -> Date = { Date() },
                stateDirectory: String? = nil) {
        self.init(runner: runner, credentials: credentials, claudePath: { claudePath },
                  allowPromptFallback: allowPromptFallback, isOnline: isOnline, now: now,
                  stateDirectory: stateDirectory)
    }

    /// - Parameter authRejected: the server answered 401/403 for this account. That is
    ///   the authoritative word on the token and it outranks `expiresAt`, so the "still
    ///   fresh" shortcut is skipped for as long as the rejection stands; the attempt
    ///   floor is bypassed ONCE (see `Attempt.forced`).
    public func ensureFresh(configDir: String, authRejected: Bool = false) async -> TokenRefreshOutcome {
        loadStateIfNeeded()
        let at = now()
        // First, before the Keychain and before any bookkeeping: with no network the CLI
        // cannot refresh anything, so this cycle is not evidence about the account and
        // must leave no trace — otherwise a flight's worth of offline cycles walks the
        // breaker up to its 12 h gap for an account that was never broken.
        guard isOnline() else {
            Self.log.info("token refresh skipped for \(configDir, privacy: .public): offline")
            return .skippedOffline
        }
        guard let before = credentials.token(configDir: configDir)?.expiresAt else {
            return fail("no readable token", configDir: configDir)
        }
        if !authRejected, before.timeIntervalSince(at) > Self.threshold {
            return observedFresh(configDir: configDir)
        }
        let failures = attempts[configDir]?.failures ?? 0
        let forcesThroughTheFloor = authRejected && !(attempts[configDir]?.forced ?? false)
        if !forcesThroughTheFloor, let last = attempts[configDir]?.at,
           at.timeIntervalSince(last) < Self.retryInterval(failures: failures) {
            return .skippedRateLimited
        }
        // Recorded BEFORE the attempt, so a crash mid-`doctor` still leaves a floor;
        // `previous` is what the could-not-attempt paths roll back to.
        let previous = record(configDir: configDir, at: at, failures: failures, forced: authRejected)

        let env = ["CLAUDE_CONFIG_DIR": configDir]
        var details: [String] = []
        do {
            let result = try await runner.run(claudePath(), ["doctor"], cwd: nil, env: env, timeout: Self.doctorTimeout)
            // 127 is the shell's "command not found": a wrong "Path to claude", or a GUI
            // app's PATH without the CLI on it. The binary never ran.
            if result.exitCode == 127 {
                return couldNotAttempt(Self.detail("doctor", result) ?? "doctor exit 127",
                                       configDir: configDir, restoring: previous)
            }
            switch reread(after: before, configDir: configDir) {
            case .advanced:   return succeed(.refreshedByDoctor, configDir: configDir)
            case .unreadable: return fail("token became unreadable after claude doctor", configDir: configDir, counts: true)
            case .unchanged:  if let d = Self.detail("doctor", result) { details.append(d) }
            }
        } catch let error as GroveError where Self.cliNeverRan(error) {
            // A spawn failure or a fired watchdog says nothing about the token — and a
            // timeout is far likelier to be the network than the token, so `-p` (which
            // spends the account's limit and starts its 5-hour window) is not tried.
            return couldNotAttempt(String(describing: error), configDir: configDir, restoring: previous)
        } catch {
            return fail("claude doctor failed: \(error)", configDir: configDir, counts: true)
        }

        guard allowPromptFallback() else {
            return fail("claude doctor did not refresh the token".appending(Self.suffix(details)),
                        configDir: configDir, counts: true)
        }
        // Circuit breaker: `-p` costs limit and starts the 5-hour window. Three
        // ineffective rounds is enough to conclude it cannot fix this account.
        guard failures < Self.promptGiveUpAfter else {
            return fail("sign in again".appending(Self.suffix(details)), configDir: configDir, counts: true)
        }
        do {
            let result = try await runner.run(claudePath(), ["-p", ".", "--model", "haiku", "--max-turns", "1"],
                                              cwd: nil, env: env, timeout: Self.promptTimeout)
            switch reread(after: before, configDir: configDir) {
            case .advanced:   return succeed(.refreshedByPrompt, configDir: configDir)
            case .unreadable: return fail("token became unreadable after claude -p", configDir: configDir, counts: true)
            case .unchanged:  if let d = Self.detail("-p", result) { details.append(d) }
            }
        } catch {
            return fail("claude -p failed: \(error)", configDir: configDir, counts: true)
        }
        return fail("neither claude doctor nor claude -p refreshed the token".appending(Self.suffix(details)),
                    configDir: configDir, counts: true)
    }

    /// A CLI that never ran: the spawn failed, or the watchdog killed it before it could
    /// say anything. Distinct from `processFailed`, which is a CLI that DID run and
    /// reported something — real evidence about the account, and counted as such.
    private static func cliNeverRan(_ error: GroveError) -> Bool {
        switch error {
        case .timeout, .io: return true
        default: return false
        }
    }

    /// 30 min, doubling with each consecutive ineffective attempt, capped at 12 h.
    static func retryInterval(failures: Int) -> TimeInterval {
        guard failures > 0 else { return attemptInterval }
        return min(attemptInterval * pow(2, Double(failures - 1)), maxAttemptInterval)
    }

    enum Reread: Sendable, Equatable {
        /// The expiry moved forward — the CLI really did refresh the token.
        case advanced
        /// Still the same expiry.
        case unchanged
        /// The token cannot be read at all any more (prompt denied, item gone). NOT
        /// the same as `unchanged`: running `-p` on a token we cannot verify spends
        /// the account's limit and starts its 5-hour window for nothing.
        case unreadable
    }

    /// Drops any cached copy and re-reads.
    private func reread(after before: Date, configDir: String) -> Reread {
        credentials.invalidate(configDir: configDir)
        guard let after = credentials.token(configDir: configDir)?.expiresAt else { return .unreadable }
        return after > before ? .advanced : .unchanged
    }

    /// A CLI result worth reporting: the exit code plus the last stderr line.
    /// Nothing to say when the command exited 0 with an empty stderr.
    static func detail(_ label: String, _ result: ProcessResult) -> String? {
        let stderr = result.stderr.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if result.exitCode == 0 && stderr.isEmpty { return nil }
        return stderr.isEmpty ? "\(label) exit \(result.exitCode)" : "\(label) exit \(result.exitCode): \(stderr)"
    }

    private static func suffix(_ details: [String]) -> String {
        details.isEmpty ? "" : " (\(details.joined(separator: "; ")))"
    }

    /// A token with more than `threshold` of life left is proof this account is
    /// healthy again — whoever moved it: a later `doctor`, Claude Code itself running
    /// in that config dir, a fresh sign-in. The breaker has to be reset HERE, because
    /// nothing else on this path ever does: `succeed` runs only when THIS keeper moved
    /// the expiry, and `ensureFresh` returns before it. With the count persisted to
    /// `token-attempts.json` a spell of three failures otherwise survived every
    /// relaunch, permanently disabling the `-p` leg and holding the retry gap at 12 h —
    /// the opposite of the spec's "always current".
    ///
    /// The attempt TIMESTAMP is deliberately kept: the spec's floor is "one
    /// token-refresh attempt per account per 30 min", and a token that was refreshed
    /// out of band is no reason to spawn the CLI sooner than that.
    ///
    /// `forced` is deliberately kept too. Getting here means `expiresAt > threshold` —
    /// which is exactly the signal `authRejected` exists to distrust, because a
    /// server-revoked token still carries hours of nominal life. Re-arming the bypass on
    /// it would hand every subsequent 401 its own `doctor`, forever. Only `succeed`
    /// clears it: there the CLI verifiably MOVED the expiry, which no revoked token can
    /// fake. A `forced` left standing cannot lock out a later genuine 401 either — by
    /// then the recorded attempt is old and the ordinary floor check lets the call
    /// through anyway.
    private func observedFresh(configDir: String) -> TokenRefreshOutcome {
        if var attempt = attempts[configDir], attempt.failures != 0 {
            attempt.failures = 0
            attempts[configDir] = attempt
            saveState()
        }
        return .fresh
    }

    private func succeed(_ outcome: TokenRefreshOutcome, configDir: String) -> TokenRefreshOutcome {
        if var attempt = attempts[configDir] {
            attempt.failures = 0
            // A refresh this keeper watched land ends the rejection episode: the NEXT 401
            // is a new one and deserves its own bypass, not the leftovers of this one.
            // This is the ONLY place `forced` is cleared — see `observedFresh` for why a
            // merely plausible `expiresAt` does not qualify.
            attempt.forced = false
            attempts[configDir] = attempt
            saveState()
        }
        return outcome
    }

    /// Nothing is swallowed: the reason goes to the unified log AND back to the
    /// caller, which puts it in the account row's status slot.
    private func fail(_ reason: String, configDir: String, counts: Bool = false) -> TokenRefreshOutcome {
        Self.log.error("token refresh failed for \(configDir, privacy: .public): \(reason, privacy: .public)")
        if counts, var attempt = attempts[configDir] {
            attempt.failures += 1
            attempts[configDir] = attempt
            saveState()
        }
        return .failed(reason)
    }

    /// Nothing is swallowed here either: the CLI's silence is logged and travels back to
    /// the account row. Nothing is charged for it, though — the attempt record is rolled
    /// back, so the floor and the breaker are exactly where they were.
    private func couldNotAttempt(_ reason: String, configDir: String, restoring previous: Attempt?) -> TokenRefreshOutcome {
        Self.log.error("token refresh not attempted for \(configDir, privacy: .public): \(reason, privacy: .public)")
        unrecord(configDir: configDir, restoring: previous)
        return .couldNotAttempt(reason)
    }

    /// Returns what was there before, for `unrecord` to put back.
    private func record(configDir: String, at: Date, failures: Int, forced: Bool) -> Attempt? {
        let previous = attempts[configDir]
        attempts[configDir] = Attempt(at: at, failures: failures, forced: forced)
        saveState()
        return previous
    }

    private func unrecord(configDir: String, restoring previous: Attempt?) {
        if let previous { attempts[configDir] = previous } else { attempts.removeValue(forKey: configDir) }
        saveState()
    }

    // MARK: - persistence

    private var stateFile: String? { stateDirectory.map { $0 + "/token-attempts.json" } }

    private func loadStateIfNeeded() {
        guard !loadedState else { return }
        loadedState = true
        guard let path = stateFile, let data = FileManager.default.contents(atPath: path) else { return }
        do { attempts = try JSONDecoder().decode([String: Attempt].self, from: data) }
        catch { Self.log.error("token attempt state unreadable at \(path, privacy: .public): \(String(describing: error), privacy: .public)") }
    }

    private func saveState() {
        guard let directory = stateDirectory, let path = stateFile else { return }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(attempts).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            Self.log.error("token attempt state unwritable at \(path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
