import Foundation
import CryptoKit
import Security

/// Supplies a Claude Code OAuth access token for an account's config dir. A
/// protocol so the OAuth client can be tested with a canned token (no Keychain).
public protocol CredentialsReading: Sendable {
    /// The OAuth bearer for `configDir`, or nil when none is available.
    func accessToken(configDir: String) -> String?
}

/// Production credentials source. Claude Code stores each account's OAuth blob in
/// the macOS login Keychain as a generic password:
/// - default account (configDir == ~/.claude): service `Claude Code-credentials`
/// - custom CLAUDE_CONFIG_DIR: service `Claude Code-credentials-<h>` where `<h>`
///   is the first 8 hex chars of sha256(expanded configDir, no trailing slash).
///
/// The stored value is the same JSON as the legacy `<configDir>/.credentials.json`
/// (`{"claudeAiOauth":{"accessToken":…}}`), which remains a fallback for older
/// installs. Reading another app's Keychain item may prompt the user once to grant
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

    public func accessToken(configDir: String) -> String? {
        // 1) Keychain (the modern store).
        if let blob = Self.keychainSecret(service: Self.serviceName(configDir: configDir)),
           let token = Self.parseToken(blob) {
            return token
        }
        // 2) Legacy file (older Claude Code installs).
        let path = Self.expandedDir(configDir) + "/.credentials.json"
        if let data = FileManager.default.contents(atPath: path),
           let token = Self.parseToken(data) {
            return token
        }
        return nil
    }

    // MARK: - helpers (internal for tests)

    /// Pulls `claudeAiOauth.accessToken` (or a top-level `accessToken`) from a
    /// credentials JSON blob. nil when absent/empty/malformed.
    static func parseToken(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            return token
        }
        if let token = json["accessToken"] as? String, !token.isEmpty {
            return token
        }
        return nil
    }

    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
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

/// Caches each account's OAuth token in memory for the process lifetime so the
/// macOS Keychain — which prompts the user when Grove reads Claude Code's item — is
/// hit AT MOST ONCE per account per launch. The OAuth client otherwise re-read the
/// token on every poll (its result cache is only ~3 min), which re-prompted the user
/// repeatedly while the panel was open. Claude Code's token is long-lived (it
/// refreshes on its own cadence); a token that goes stale surfaces as an OAuth auth
/// failure, after which `invalidate(configDir:)` forces a fresh read. Only SUCCESSFUL
/// reads are cached, so a transient nil (e.g. the user dismissing the first prompt)
/// is retried on the next poll. Thread-safe via a lock.
public final class CachingCredentialsReader: CredentialsReading, @unchecked Sendable {
    private let base: CredentialsReading
    private let lock = NSLock()
    private var cache: [String: String] = [:]   // configDir → token (successful reads only)

    public init(base: CredentialsReading = KeychainCredentialsReader()) {
        self.base = base
    }

    public func accessToken(configDir: String) -> String? {
        lock.lock()
        if let cached = cache[configDir] { lock.unlock(); return cached }
        lock.unlock()
        guard let token = base.accessToken(configDir: configDir) else { return nil }
        lock.lock(); cache[configDir] = token; lock.unlock()
        return token
    }

    /// Drop a cached token so the next read re-fetches from the Keychain — call this
    /// when an OAuth request fails auth (the token may have been refreshed).
    public func invalidate(configDir: String) {
        lock.lock(); cache.removeValue(forKey: configDir); lock.unlock()
    }
}
