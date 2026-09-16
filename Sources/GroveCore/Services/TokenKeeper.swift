import Foundation
import os

public enum TokenRefreshOutcome: Sendable, Equatable {
    /// More than `TokenKeeper.threshold` of life remained; nothing was run.
    case fresh
    /// An attempt ran less than the current retry interval ago; nothing was run.
    case skippedRateLimited
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
/// forward. Exit codes are not trusted as success — but they ARE reported, so a
/// `claude` that exits 127 says so instead of hiding behind "neither … refreshed
/// the token".
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
    }

    private let runner: CommandRunning
    private let credentials: CredentialsReading
    /// Read through a closure, not captured once: Settings › General can correct a
    /// wrong "Path to claude" at any time and the next cycle must use the new one.
    private let claudePath: @Sendable () -> String
    private let allowPromptFallback: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    /// nil → attempts live in memory only (tests, and any caller that wants no file).
    private let stateDirectory: String?
    private var attempts: [String: Attempt] = [:]
    private var loadedState = false

    public init(runner: CommandRunning, credentials: CredentialsReading,
                claudePath: @escaping @Sendable () -> String,
                allowPromptFallback: @escaping @Sendable () -> Bool,
                now: @escaping @Sendable () -> Date = { Date() },
                stateDirectory: String? = nil) {
        self.runner = runner
        self.credentials = credentials
        self.claudePath = claudePath
        self.allowPromptFallback = allowPromptFallback
        self.now = now
        self.stateDirectory = stateDirectory
    }

    /// Fixed-path convenience (tests and any caller whose path cannot change).
    public init(runner: CommandRunning, credentials: CredentialsReading, claudePath: String,
                allowPromptFallback: @escaping @Sendable () -> Bool,
                now: @escaping @Sendable () -> Date = { Date() },
                stateDirectory: String? = nil) {
        self.init(runner: runner, credentials: credentials, claudePath: { claudePath },
                  allowPromptFallback: allowPromptFallback, now: now, stateDirectory: stateDirectory)
    }

    public func ensureFresh(configDir: String) async -> TokenRefreshOutcome {
        loadStateIfNeeded()
        let at = now()
        guard let before = credentials.token(configDir: configDir)?.expiresAt else {
            return fail("no readable token", configDir: configDir)
        }
        if before.timeIntervalSince(at) > Self.threshold { return observedFresh(configDir: configDir) }
        let failures = attempts[configDir]?.failures ?? 0
        if let last = attempts[configDir]?.at,
           at.timeIntervalSince(last) < Self.retryInterval(failures: failures) {
            return .skippedRateLimited
        }
        record(configDir: configDir, at: at, failures: failures)

        let env = ["CLAUDE_CONFIG_DIR": configDir]
        var details: [String] = []
        do {
            let result = try await runner.run(claudePath(), ["doctor"], cwd: nil, env: env, timeout: Self.doctorTimeout)
            switch reread(after: before, configDir: configDir) {
            case .advanced:   return succeed(.refreshedByDoctor, configDir: configDir)
            case .unreadable: return fail("token became unreadable after claude doctor", configDir: configDir, counts: true)
            case .unchanged:  if let d = Self.detail("doctor", result) { details.append(d) }
            }
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

    private func record(configDir: String, at: Date, failures: Int) {
        attempts[configDir] = Attempt(at: at, failures: failures)
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
