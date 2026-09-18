import Foundation
import CryptoKit
import Security
import os

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

/// What a credentials read came back with. Three answers, not an optional: "there
/// is no token" and "there is one, but the Keychain will not hand it over without
/// asking the user" call for different things on screen.
public enum CredentialsAccess: Sendable, Equatable {
    case token(ClaudeToken)
    case missing
    /// The item exists but reading it needs the user's consent (the app is not on its
    /// access list, or the request was refused). With Keychain UI switched off for the
    /// process this is what an ungranted item answers INSTEAD of blocking on a dialog.
    case locked
}

/// Supplies a Claude Code OAuth access token for an account's config dir. A
/// protocol so the OAuth client can be tested with a canned token (no Keychain).
/// A conformer implements `token` or `accessToken` and gets `access` for free; one
/// that implements `access` (the two production readers) also implements `token`
/// from it, since the `token` ↔ `accessToken` bridge cannot know about it.
public protocol CredentialsReading: Sendable {
    /// The full answer — see `CredentialsAccess`.
    func access(configDir: String) -> CredentialsAccess
    /// The bearer for `configDir` with its expiry, or nil when none is available.
    func token(configDir: String) -> ClaudeToken?
    /// The bearer value alone, for callers that don't care about the lifetime.
    func accessToken(configDir: String) -> String?
    /// Drop any cached copy of this account's token so the next read goes back to the
    /// source. Called when the endpoint rejects the bearer — the credential may have
    /// been rotated behind our back. A no-op for readers that hold no cache.
    func invalidate(configDir: String)
    /// A read the USER asked for: allowed to put the Keychain dialog up. The one
    /// place a `.locked` item becomes readable — "Always Allow" there is permanent.
    func grant(configDir: String) -> CredentialsAccess
}

public extension CredentialsReading {
    /// From `token`, not `accessToken`: the expiry must survive the bridge.
    func access(configDir: String) -> CredentialsAccess {
        token(configDir: configDir).map(CredentialsAccess.token) ?? .missing
    }
    func token(configDir: String) -> ClaudeToken? {
        accessToken(configDir: configDir).map { ClaudeToken(value: $0, expiresAt: nil) }
    }
    func accessToken(configDir: String) -> String? {
        token(configDir: configDir)?.value
    }
    func invalidate(configDir: String) {}
    func grant(configDir: String) -> CredentialsAccess { access(configDir: configDir) }
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
        if case .token(let token) = access(configDir: configDir) { return token }
        return nil
    }

    public func access(configDir: String) -> CredentialsAccess {
        // 1) Keychain (the modern store).
        switch Self.keychainSecret(service: Self.serviceName(configDir: configDir)) {
        case .found(let blob):
            if let token = Self.parseClaudeToken(blob) { return .token(token) }
        case .locked:
            return .locked
        case .absent:
            break
        }
        // 2) Legacy file (older Claude Code installs).
        let path = Self.expandedDir(configDir) + "/.credentials.json"
        if let data = FileManager.default.contents(atPath: path),
           let token = Self.parseClaudeToken(data) {
            return .token(token)
        }
        return .missing
    }

    /// The read that may ask. Keychain UI is re-enabled for just this call, so the
    /// dialog the user chose to see is the only one they ever see.
    public func grant(configDir: String) -> CredentialsAccess {
        Self.withUserInteraction { access(configDir: configDir) }
    }

    /// Whether ANY Keychain read in this process may put a dialog up. Brow switches it
    /// off at launch: a background poll that hits an ungranted item must come back
    /// `.locked` at once, not park a whole refresh cycle behind a modal until the
    /// watchdog throws the cycle — and every reading in it — away. Grove keeps the
    /// default (on): it reads the Keychain only on the user's own gesture.
    public static func setUserInteractionAllowed(_ allowed: Bool) {
        SecKeychainSetUserInteractionAllowed(allowed)
    }

    static func withUserInteraction<T>(_ body: () -> T) -> T {
        var was: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&was)
        SecKeychainSetUserInteractionAllowed(true)
        defer { SecKeychainSetUserInteractionAllowed(was.boolValue) }
        return body()
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

    private enum Secret { case found(Data), absent, locked }

    /// Two ways in, the tool first. Claude Code writes every item with
    /// `security add-generic-password`, which puts `apple-tool:` on the item's
    /// partition list — so `/usr/bin/security`, Apple-signed, reads it back with no
    /// grant and no dialog; it is how Claude Code itself reads. The API path needs
    /// this app on the item's own access list, a grant the user gives per item and
    /// the CLI drops whenever it rewrites one, which is what made an account go
    /// "Keychain access needed" hours after "Always Allow" was chosen for it.
    private static func keychainSecret(service: String) -> Secret {
        switch securityTool(service: service) {
        case .found(let data): return .found(data)
        case .absent: return .absent
        case .locked: break                        // the tool could not: ask the API
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return (item as? Data).map(Secret.found) ?? .absent
        // Interaction switched off (the item needs a grant), the grant refused, or the
        // dialog dismissed: the item is there, we may not have it.
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            log.error("keychain read withheld for \(service, privacy: .public): status \(status, privacy: .public)")
            return .locked
        default:
            return .absent
        }
    }

    /// `security find-generic-password -s <service> -w`: the stored bytes (Claude
    /// Code's JSON) on stdout, exit 44 for no such item. `.locked` for any other
    /// failure, including a hang — the tool must never park a read on a dialog of
    /// its own, so it gets ten seconds.
    private static func securityTool(service: String) -> Secret {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .locked }
        let deadline = DispatchTime.now() + 10
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { process.waitUntilExit(); done.signal() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            log.error("security tool timed out reading \(service, privacy: .public)")
            return .locked
        }
        switch process.terminationStatus {
        case 0:
            var bytes = data
            while let last = bytes.last, last == 0x0A || last == 0x0D { bytes.removeLast() }
            return bytes.isEmpty ? .absent : .found(bytes)
        case 44:
            return .absent                          // errSecItemNotFound
        default:
            log.error("security tool failed for \(service, privacy: .public): exit \(process.terminationStatus, privacy: .public)")
            return .locked
        }
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "grove", category: "keychain")
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
/// backstop for a token revoked before its stated expiry.
///
/// A FAILED read is remembered too, for `nilReadFloor`. It costs the user exactly as
/// much as a successful one: once the Keychain ACL grant is missing or denied, every
/// `SecItemCopyMatching` raises the modal again, and the Brow cycle runs every 60 s —
/// an uncached nil is a prompt a minute, forever. `invalidate(configDir:)` clears the
/// record, and `LimitsStore` calls it for every known dir at the top of every FORCED
/// cycle — ⟳, wake, the network returning, the end of "Add account…" — so granting
/// access (or finishing `claude auth login`) takes effect on the user's next gesture
/// rather than whenever the ten minutes happen to run out. Thread-safe via a lock.
///
/// Reads are also SINGLE-FLIGHT per config dir: a second caller that arrives while a
/// read is out waits for that read's answer instead of issuing its own. The cache alone
/// cannot dedupe them — it is filled when a read RETURNS, and a read parked on a modal
/// prompt has not returned — so the Brow cycle's scan, `TokenKeeper` and the usage fetch
/// could each raise their own prompt for the same account, which is precisely the
/// multi-prompt first run that single-flight discovery exists to prevent.
public final class CachingCredentialsReader: CredentialsReading, @unchecked Sendable {
    /// Refresh this long BEFORE the stated expiry, so a token can't die in flight
    /// between the cache read and the endpoint receiving it.
    private static let skew: TimeInterval = 60
    /// Floor between two Keychain reads of an ALREADY-EXPIRED token. Such a token is
    /// never "live", so without this every caller in a cycle (the account scan, the
    /// TokenKeeper read, the post-CLI re-read, the usage fetch) goes back to the
    /// Keychain — a modal prompt every two minutes if the ACL grant is ever lost, for
    /// a value that cannot have changed. `invalidate(configDir:)` still bypasses it,
    /// so a token the CLI just refreshed is picked up immediately.
    private static let expiredReadFloor: TimeInterval = 60
    /// Floor between two base reads that returned NOTHING. A denied — or merely
    /// dismissed — Keychain prompt makes the next read prompt again, so without this
    /// the user is asked once per poll cycle for a credential Grove has already been
    /// told it cannot have. Ten minutes is long enough to stop being a nuisance and
    /// short enough that a credential appearing on its own is picked up unprompted;
    /// `invalidate(configDir:)` bypasses it entirely.
    public static let nilReadFloor: TimeInterval = 600

    private struct Entry { let token: ClaudeToken; let readAt: Date }

    private let base: CredentialsReading
    private let now: @Sendable () -> Date
    /// Guards the three maps below AND is the condition followers wait on. One object,
    /// because a follower has to re-read the cache the moment the winner publishes.
    private let gate = NSCondition()
    private var cache: [String: Entry] = [:]   // configDir → token (successful reads only)
    private var nilReadAt: [String: Date] = [:]  // configDir → when the base last gave nothing
    /// Dirs whose last empty-handed read was `.locked` rather than `.missing`, so the
    /// floored answer keeps saying which.
    private var locked: Set<String> = []
    /// Config dirs with a base read out right now.
    private var inFlight: Set<String> = []

    public init(base: CredentialsReading = KeychainCredentialsReader(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.base = base
        self.now = now
    }

    public func token(configDir: String) -> ClaudeToken? {
        if case .token(let token) = access(configDir: configDir) { return token }
        return nil
    }

    public func access(configDir: String) -> CredentialsAccess {
        let at = now()
        gate.lock()
        while true {
            if let cached = cache[configDir],
               Self.isLive(cached.token, at: at) || Self.withinExpiredFloor(cached, at: at) {
                gate.unlock()
                return .token(cached.token)
            }
            if let failedAt = nilReadAt[configDir], at.timeIntervalSince(failedAt) < Self.nilReadFloor {
                let answer: CredentialsAccess = locked.contains(configDir) ? .locked : .missing
                gate.unlock()
                return answer
            }
            // Someone is already asking the Keychain for this dir: wait for THEIR
            // answer and then re-run the two checks above against it, rather than
            // raising a second modal prompt for the same item.
            guard inFlight.contains(configDir) else { break }
            gate.wait()
        }
        inFlight.insert(configDir)
        gate.unlock()

        let fresh = base.access(configDir: configDir)
        // Stamped when the read RETURNED, not when it started. A read parked on a modal
        // prompt can sit for minutes, and dating the floor from the start of it burns
        // part of the window on the wait — the opposite of what the floor is for.
        let returnedAt = now()
        gate.lock()
        record(fresh, for: configDir, at: returnedAt)
        inFlight.remove(configDir)
        gate.broadcast()
        gate.unlock()
        return fresh
    }

    /// The user's own read: floors and cache dropped first so the base is really asked,
    /// and whatever it answers is what the next cycle sees.
    public func grant(configDir: String) -> CredentialsAccess {
        invalidate(configDir: configDir)
        let fresh = base.grant(configDir: configDir)
        gate.lock()
        record(fresh, for: configDir, at: now())
        gate.unlock()
        return fresh
    }

    /// Caller holds `gate`.
    private func record(_ answer: CredentialsAccess, for configDir: String, at instant: Date) {
        switch answer {
        case .token(let token):
            cache[configDir] = Entry(token: token, readAt: instant)
            nilReadAt.removeValue(forKey: configDir)
            locked.remove(configDir)
        case .missing:
            nilReadAt[configDir] = instant
            locked.remove(configDir)
        case .locked:
            nilReadAt[configDir] = instant
            locked.insert(configDir)
        }
    }

    /// Drop a cached token — and any record of a failed read — so the next call goes
    /// back to the Keychain. Called when an OAuth request fails auth (the token may
    /// have been rotated early) and whenever the user may have just granted access.
    public func invalidate(configDir: String) {
        gate.lock()
        cache.removeValue(forKey: configDir)
        nilReadAt.removeValue(forKey: configDir)
        locked.remove(configDir)
        gate.unlock()
    }

    /// A token is usable while it is more than `skew` away from its own expiry. No
    /// expiry means no known deadline, so it stays usable.
    private static func isLive(_ token: ClaudeToken, at instant: Date) -> Bool {
        guard let expiresAt = token.expiresAt else { return true }
        return instant.addingTimeInterval(skew) < expiresAt
    }

    /// Applies ONLY once the token is past its own expiry — a token merely inside the
    /// 60 s skew is still valid and a re-read may pick up a just-rotated one, so that
    /// case keeps going to the base reader.
    private static func withinExpiredFloor(_ entry: Entry, at instant: Date) -> Bool {
        guard let expiresAt = entry.token.expiresAt, expiresAt <= instant else { return false }
        return instant.timeIntervalSince(entry.readAt) < expiredReadFloor
    }
}
