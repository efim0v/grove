import Foundation
import os

public enum TokenRefreshOutcome: Sendable, Equatable {
    /// More than `TokenKeeper.threshold` of life remained; nothing was run.
    case fresh
    /// An attempt ran less than `attemptInterval` ago; nothing was run.
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
/// forward. Exit codes are not trusted.
public actor TokenKeeper {
    public static let threshold: TimeInterval = 30 * 60
    public static let attemptInterval: TimeInterval = 30 * 60
    static let doctorTimeout: TimeInterval = 90
    static let promptTimeout: TimeInterval = 120

    private static let log = Logger(subsystem: "dev.artemefimov.brow", category: "TokenKeeper")

    private let runner: CommandRunning
    private let credentials: CredentialsReading
    private let claudePath: String
    private let allowPromptFallback: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private var lastAttempt: [String: Date] = [:]

    public init(runner: CommandRunning, credentials: CredentialsReading, claudePath: String,
                allowPromptFallback: @escaping @Sendable () -> Bool,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.credentials = credentials
        self.claudePath = claudePath
        self.allowPromptFallback = allowPromptFallback
        self.now = now
    }

    public func ensureFresh(configDir: String) async -> TokenRefreshOutcome {
        let at = now()
        guard let before = credentials.token(configDir: configDir)?.expiresAt else {
            return fail("no readable token", configDir: configDir)
        }
        if before.timeIntervalSince(at) > Self.threshold { return .fresh }
        if let last = lastAttempt[configDir], at.timeIntervalSince(last) < Self.attemptInterval {
            return .skippedRateLimited
        }
        lastAttempt[configDir] = at

        let env = ["CLAUDE_CONFIG_DIR": configDir]
        do {
            _ = try await runner.run(claudePath, ["doctor"], cwd: nil, env: env, timeout: Self.doctorTimeout)
        } catch {
            return fail("claude doctor failed: \(error)", configDir: configDir)
        }
        if moved(from: before, configDir: configDir) { return .refreshedByDoctor }

        guard allowPromptFallback() else {
            return fail("claude doctor did not refresh the token", configDir: configDir)
        }
        do {
            _ = try await runner.run(claudePath, ["-p", ".", "--model", "haiku", "--max-turns", "1"],
                                     cwd: nil, env: env, timeout: Self.promptTimeout)
        } catch {
            return fail("claude -p failed: \(error)", configDir: configDir)
        }
        if moved(from: before, configDir: configDir) { return .refreshedByPrompt }
        return fail("neither claude doctor nor claude -p refreshed the token", configDir: configDir)
    }

    /// Drops any cached copy and re-reads; true when the expiry advanced.
    private func moved(from before: Date, configDir: String) -> Bool {
        credentials.invalidate(configDir: configDir)
        guard let after = credentials.token(configDir: configDir)?.expiresAt else { return false }
        return after > before
    }

    /// Nothing is swallowed: the reason goes to the unified log AND back to the
    /// caller, which puts it in the account row's status slot.
    private func fail(_ reason: String, configDir: String) -> TokenRefreshOutcome {
        Self.log.error("token refresh failed for \(configDir, privacy: .public): \(reason, privacy: .public)")
        return .failed(reason)
    }
}
