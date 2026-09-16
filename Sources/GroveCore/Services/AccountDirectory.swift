import Foundation

/// One Claude account as Brow sees it: an organisation, reachable through one
/// or more Claude Code config dirs. Several dirs can hold the same account (the
/// user's `work-account` and `me@example.com` dirs are one org), so
/// the unit of identity is `organizationUuid`, never the directory.
public struct DiscoveredAccount: Sendable, Equatable, Identifiable {
    public var id: String { organizationUuid }
    public let organizationUuid: String
    public let email: String?
    /// `oauthAccount.organizationRateLimitTier` — the namespace `RateLimitModel.tierWeights` keys on.
    public let tier: String?
    /// The dir whose Keychain token expires latest: the one to fetch limits with.
    public let configDir: String
    /// Other dirs that resolve to the same organisation.
    public let aliasDirs: [String]
    /// Expiry of `configDir`'s token; nil when no token is readable at all.
    public let tokenExpiresAt: Date?

    public init(organizationUuid: String, email: String?, tier: String?, configDir: String,
                aliasDirs: [String], tokenExpiresAt: Date?) {
        self.organizationUuid = organizationUuid
        self.email = email
        self.tier = tier
        self.configDir = configDir
        self.aliasDirs = aliasDirs
        self.tokenExpiresAt = tokenExpiresAt
    }
}

/// Finds Claude Code config dirs on disk and folds them into accounts.
/// Pure over the filesystem + the injected credentials reader; `home` is
/// injectable so tests build a fake `$HOME`.
public struct AccountDirectory: Sendable {
    private let home: String
    private let credentials: CredentialsReading

    public init(home: String = NSHomeDirectory(), credentials: CredentialsReading) {
        self.home = home
        self.credentials = credentials
    }

    /// `~/.claude`, then `~/.claude-accounts/*` (name order), then `extraDirs`;
    /// dirs sharing an organisation collapse into one account at the FIRST
    /// position, with `configDir` = the dir whose token expires latest.
    public func scan(extraDirs: [String] = []) -> [DiscoveredAccount] {
        var order: [String] = []                       // org uuids, first-seen order
        // The identity travels WITH each member dir: `configDir` comes from the
        // freshest-token dir, so its email/tier must come from the same dir. Taking
        // them from the first-seen dir instead labelled an account with one
        // directory's metadata while fetching with another's token — and a `tier`
        // read from a dir written by an older CLI silently weighs the account at
        // 1/20th of its real capacity in the tier-weighted aggregate.
        var members: [String: [(dir: String, expiry: Date?, email: String?, tier: String?)]] = [:]
        for dir in Self.candidateDirs(home: home, extraDirs: extraDirs) {
            guard let id = Self.identity(configDir: dir, home: home) else { continue }
            let expiry = credentials.token(configDir: dir)?.expiresAt
            if members[id.org] == nil { order.append(id.org) }
            members[id.org, default: []].append((dir, expiry, id.email, id.tier))
        }
        return order.compactMap { org in
            let dirs = members[org] ?? []
            // Latest expiry first; a dir with no token sorts last. Stable for ties.
            let ranked = dirs.enumerated().sorted { a, b in
                switch (a.element.expiry, b.element.expiry) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.offset < b.offset
                }
            }.map(\.element)
            guard let primary = ranked.first else { return nil }
            // Primary first; a member that still carries the field is the fallback,
            // so a primary dir whose `.claude.json` predates `organizationRateLimitTier`
            // does not erase a tier another dir of the same org knows.
            let email = primary.email ?? ranked.first { $0.email != nil }?.email
            let tier = primary.tier ?? ranked.first { $0.tier != nil }?.tier
            return DiscoveredAccount(organizationUuid: org,
                                     email: email, tier: tier,
                                     configDir: primary.dir,
                                     aliasDirs: ranked.dropFirst().map(\.dir),
                                     tokenExpiresAt: primary.expiry)
        }
    }

    /// Existing directories only, tilde-expanded, in the documented order.
    static func candidateDirs(home: String, extraDirs: [String]) -> [String] {
        let fm = FileManager.default
        var dirs: [String] = []
        let defaultDir = home + "/.claude"
        if fm.fileExists(atPath: defaultDir) { dirs.append(defaultDir) }
        let accountsRoot = home + "/.claude-accounts"
        if let names = try? fm.contentsOfDirectory(atPath: accountsRoot) {
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = accountsRoot + "/" + name
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { dirs.append(path) }
            }
        }
        for raw in extraDirs {
            let path = expandTilde(raw)
            if fm.fileExists(atPath: path), !dirs.contains(path) { dirs.append(path) }
        }
        return dirs
    }

    /// Reads `oauthAccount` from the dir's `.claude.json`. The default account
    /// keeps that file in `$HOME`, custom dirs keep it inside the dir — same rule
    /// as `AppState.claudeJSONPath(for:)`.
    public static func identity(configDir: String, home: String) -> (org: String, email: String?, tier: String?)? {
        let path = configDir == home + "/.claude" ? home + "/.claude.json" : configDir + "/.claude.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = json["oauthAccount"] as? [String: Any],
              let org = oauth["organizationUuid"] as? String, !org.isEmpty
        else { return nil }
        return (org, oauth["emailAddress"] as? String, oauth["organizationRateLimitTier"] as? String)
    }
}
