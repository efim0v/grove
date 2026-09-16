import Foundation
import CryptoKit
import Security

/// A Claude Code OAuth bearer together with the moment it stops being accepted.
///
/// The expiry is NOT decoration: Claude Code's access token lives ~8 hours and the CLI
/// rotates it on its own cadence, so any component that holds one has to know when its
/// copy went dead. `expiresAt == nil` means "lifetime unknown" (a legacy
/// `.credentials.json` without the field) — treated as "no scheduled expiry", never as
/// "already expired".
public struct ClaudeToken: Sendable, Equatable {
    public let value: String
    public let expiresAt: Date?
    public init(value: String, expiresAt: Date?) {
        self.value = value
        self.expiresAt = expiresAt
    }
}

/// Supplies a Claude Code OAuth access token for an account's config dir. A
/// protocol so the OAuth client can be tested with a canned token (no Keychain).
public protocol CredentialsReading: Sendable {
    /// The bearer for `configDir` with its expiry, or nil when none is available.
    func token(configDir: String) -> ClaudeToken?
    /// The bearer value alone, for callers that don't care about the lifetime.
    func accessToken(configDir: String) -> String?
    /// Drop any cached copy of this account's token so the next read goes back to the
    /// source. Called when the endpoint rejects the bearer — the credential may have
    /// been rotated behind our back. A no-op for readers that hold no cache.
    func invalidate(configDir: String)
}

public extension CredentialsReading {
    /// Default bridge so a conformer only has to implement ONE of the two accessors.
    func token(configDir: String) -> ClaudeToken? {
        accessToken(configDir: configDir).map { ClaudeToken(value: $0, expiresAt: nil) }
    }
    func accessToken(configDir: String) -> String? {
        token(configDir: configDir)?.value
    }
    func invalidate(configDir: String) {}
}

/// Production credentials source. Claude Code stores each account's OAuth blob in
/// the macOS login Keychain as a generic password:
/// - default account (configDir == ~/.claude): service `Claude Code-credentials`
/// - custom CLAUDE_CONFIG_DIR: service `Claude Code-credentials-<h>` where `<h>`
///   is the first 8 hex chars of sha256(expanded configDir, no trailing slash).
///
/// The stored value is the same JSON as the legacy `<configDir>/.credentials.json`
/// (`{"claudeAiOauth":{"accessToken":…,"expiresAt":…}}`), which remains a fallback for
/// older installs. Reading another app's Keychain item may prompt the user once to grant
/// access; that's expected and only happens for accounts whose limits aren't
/// already available from the statusline.
public struct KeychainCredentialsReader: CredentialsReading {
    public init() {}

    /// The Keychain service name Claude Code uses for `configDir`.
    public static func serviceName(configDir: String) -> String {
        let dir = expandedDir(configDir)
        if dir == NSHomeDirectory() + "/.claude" { return "Claude Code-credentials" }
        return "Claude Code-credentials-\(accountKey(dir))"
    }

    public func token(configDir: String) -> ClaudeToken? {
        // 1) Keychain (the modern store).
        if let blob = Self.keychainSecret(service: Self.serviceName(configDir: configDir)),
           let token = Self.parseClaudeToken(blob) {
            return token
        }
        // 2) Legacy file (older Claude Code installs).
        let path = Self.expandedDir(configDir) + "/.credentials.json"
        if let data = FileManager.default.contents(atPath: path),
           let token = Self.parseClaudeToken(data) {
            return token
        }
        return nil
    }

    // MARK: - helpers (internal for tests)

    /// Pulls `claudeAiOauth.accessToken` (or a top-level `accessToken`) from a
    /// credentials JSON blob. nil when absent/empty/malformed.
    static func parseToken(_ data: Data) -> String? {
        parseClaudeToken(data)?.value
    }

    /// Pulls the bearer AND its expiry. Claude Code writes `expiresAt` as epoch
    /// MILLISECONDS; a missing or unusable value yields a nil expiry rather than a
    /// nil token, so an old credential file still authenticates.
    static func parseClaudeToken(_ data: Data) -> ClaudeToken? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let container = (json["claudeAiOauth"] as? [String: Any]) ?? json
        guard let value = container["accessToken"] as? String, !value.isEmpty else { return nil }
        let millis: Double?
        if let n = container["expiresAt"] as? Double { millis = n }
        else if let n = container["expiresAt"] as? Int { millis = Double(n) }
        else { millis = nil }
        return ClaudeToken(value: value,
                           expiresAt: millis.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    private static func expandedDir(_ configDir: String) -> String {
        // Drop a single trailing slash so the hash matches Claude Code's keying.
        var dir = (configDir as NSString).expandingTildeInPath
        if dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
        return dir
    }

    private static func keychainSecret(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }
}

/// Caches each account's OAuth token in memory so the macOS Keychain — which prompts
/// the user when Grove reads Claude Code's item — is hit as rarely as possible. The
/// OAuth client would otherwise re-read the token on every poll (its result cache is
/// only ~3 min), which re-prompted the user repeatedly while the panel was open.
///
/// The cache is bounded by the TOKEN'S OWN `expiresAt`, not by the process lifetime.
/// Caching for the lifetime of the app was the cause of a silent, days-long outage:
/// Grove is a menu bar app that runs for weeks, Claude Code rotates the access token
/// roughly every 8 hours, and a token pinned at launch is dead by the next morning —
/// every usage request answered 401, so the limits panel showed the last good capture
/// forever and the Refresh button appeared to do nothing. Expiring the entry when the
/// credential itself expires means at most one extra Keychain read per token rotation.
///
/// `expiresAt == nil` (legacy credential files) keeps the old cache-for-the-process
/// behaviour — there is no better bound available — and `invalidate(configDir:)` is the
/// backstop for a token revoked before its stated expiry. Only SUCCESSFUL reads are
/// cached, so a transient nil (e.g. the user dismissing the first prompt) is retried on
/// the next poll. Thread-safe via a lock.
public final class CachingCredentialsReader: CredentialsReading, @unchecked Sendable {
    /// Refresh this long BEFORE the stated expiry, so a token can't die in flight
    /// between the cache read and the endpoint receiving it.
    private static let skew: TimeInterval = 60

    private let base: CredentialsReading
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cache: [String: ClaudeToken] = [:]   // configDir → token (successful reads only)

    public init(base: CredentialsReading = KeychainCredentialsReader(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.base = base
        self.now = now
    }

    public func token(configDir: String) -> ClaudeToken? {
        let at = now()
        lock.lock()
        if let cached = cache[configDir], Self.isLive(cached, at: at) {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let fresh = base.token(configDir: configDir) else { return nil }
        lock.lock(); cache[configDir] = fresh; lock.unlock()
        return fresh
    }

    /// Drop a cached token so the next read re-fetches from the Keychain — called when
    /// an OAuth request fails auth (the token may have been rotated early).
    public func invalidate(configDir: String) {
        lock.lock(); cache.removeValue(forKey: configDir); lock.unlock()
    }

    /// A token is usable while it is more than `skew` away from its own expiry. No
    /// expiry means no known deadline, so it stays usable.
    private static func isLive(_ token: ClaudeToken, at instant: Date) -> Bool {
        guard let expiresAt = token.expiresAt else { return true }
        return instant.addingTimeInterval(skew) < expiresAt
    }
}
