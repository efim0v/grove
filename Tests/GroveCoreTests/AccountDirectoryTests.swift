import XCTest
@testable import GroveCore

final class AccountDirectoryTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = try Fixture.tempDir("home")
    }

    /// Writes a config dir with a .claude.json carrying an oauthAccount.
    @discardableResult
    private func makeDir(_ rel: String, org: String?, email: String? = nil, tier: String? = "default_claude_max_20x") throws -> String {
        let dir = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var oauth: [String: Any] = [:]
        if let org { oauth["organizationUuid"] = org }
        if let email { oauth["emailAddress"] = email }
        if let tier { oauth["organizationRateLimitTier"] = tier }
        let json = try JSONSerialization.data(withJSONObject: ["oauthAccount": oauth])
        // Default account keeps .claude.json in $HOME; custom dirs keep it inside the dir.
        let path = rel == ".claude" ? home.appendingPathComponent(".claude.json") : dir.appendingPathComponent(".claude.json")
        try json.write(to: path)
        return dir.path
    }

    private final class TokenTable: CredentialsReading, @unchecked Sendable {
        var expiry: [String: Date] = [:]
        func token(configDir: String) -> ClaudeToken? {
            guard let e = expiry[configDir] else { return nil }
            return ClaudeToken(value: "t", expiresAt: e)
        }
    }

    func testDiscoversDefaultAndAccountsDirsInOrder() throws {
        let a = try makeDir(".claude", org: "org-A", email: "a@x")
        let b = try makeDir(".claude-accounts/beta", org: "org-B", email: "b@x")
        let c = try makeDir(".claude-accounts/alpha", org: "org-C", email: "c@x")
        let creds = TokenTable()
        let found = AccountDirectory(home: home.path, credentials: creds).scan()
        XCTAssertEqual(found.map(\.organizationUuid), ["org-A", "org-C", "org-B"])
        XCTAssertEqual(found.map(\.configDir), [a, c, b])
        XCTAssertEqual(found[0].email, "a@x")
        XCTAssertEqual(found[0].tier, "default_claude_max_20x")
        XCTAssertNil(found[0].tokenExpiresAt, "no readable token → nil expiry, account still listed")
    }

    /// A dir whose Keychain item is withheld is still an account — one that needs a
    /// grant, which the row has to be able to say.
    func testWithheldKeychainItemMarksTheAccountLocked() throws {
        final class Locked: CredentialsReading, @unchecked Sendable {
            var lockedDirs: Set<String> = []
            func access(configDir: String) -> CredentialsAccess { lockedDirs.contains(configDir) ? .locked : .missing }
            func token(configDir: String) -> ClaudeToken? { nil }
        }
        let dir = try makeDir(".claude-accounts/held", org: "org-H", email: "h@x")
        let creds = Locked()
        creds.lockedDirs = [dir]
        let found = AccountDirectory(home: home.path, credentials: creds).scan()
        XCTAssertEqual(found.map(\.organizationUuid), ["org-H"])
        XCTAssertTrue(found[0].keychainLocked)
        XCTAssertNil(found[0].tokenExpiresAt)
        try makeDir(".claude-accounts/free", org: "org-F", email: "f@x")
        let again = AccountDirectory(home: home.path, credentials: creds).scan()
        XCTAssertEqual(again.first { $0.organizationUuid == "org-F" }?.keychainLocked, false, "missing is not locked")
    }

    func testDirWithoutOrganizationIsIgnored() throws {
        try makeDir(".claude-accounts/broken", org: nil)
        try makeDir(".claude-accounts/ok", org: "org-1")
        let found = AccountDirectory(home: home.path, credentials: TokenTable()).scan()
        XCTAssertEqual(found.map(\.organizationUuid), ["org-1"])
    }

    func testSameOrgDirsCollapseKeepingFreshestToken() throws {
        let old = try makeDir(".claude-accounts/apple", org: "org-1", email: "me@x")
        let fresh = try makeDir(".claude-accounts/me@x", org: "org-1", email: "me@x")
        let creds = TokenTable()
        creds.expiry[old] = Date(timeIntervalSince1970: 100)
        creds.expiry[fresh] = Date(timeIntervalSince1970: 200)
        let found = AccountDirectory(home: home.path, credentials: creds).scan()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].configDir, fresh, "the dir whose token expires latest wins")
        XCTAssertEqual(found[0].aliasDirs, [old])
        XCTAssertEqual(found[0].tokenExpiresAt, Date(timeIntervalSince1970: 200))
    }

    func testDirWithNoTokenSortsAfterDirWithToken() throws {
        let noTok = try makeDir(".claude-accounts/a", org: "org-1")
        let tok = try makeDir(".claude-accounts/b", org: "org-1")
        let creds = TokenTable()
        creds.expiry[tok] = Date(timeIntervalSince1970: 50)
        let found = AccountDirectory(home: home.path, credentials: creds).scan()
        XCTAssertEqual(found[0].configDir, tok)
        XCTAssertEqual(found[0].aliasDirs, [noTok])
    }

    func testExtraDirsAreMergedAndTildeExpanded() throws {
        let extra = try makeDir("elsewhere/acct", org: "org-X", email: "x@x")
        let found = AccountDirectory(home: home.path, credentials: TokenTable()).scan(extraDirs: [extra])
        XCTAssertEqual(found.map(\.organizationUuid), ["org-X"])
        // A missing extra dir is skipped, not fatal.
        let found2 = AccountDirectory(home: home.path, credentials: TokenTable()).scan(extraDirs: [extra, home.path + "/nope"])
        XCTAssertEqual(found2.count, 1)
    }

    /// `configDir` comes from the freshest-token dir, so the label must come from the
    /// SAME dir: a tier read from another dir of the org (written by an older CLI, or
    /// after a plan change) silently reweights the account in the tier-weighted
    /// aggregate — an unknown tier counts as weight 1, i.e. 1/20th of a Max 20x.
    func testEmailAndTierComeFromTheDirWhoseTokenIsFreshest() throws {
        let stale = try makeDir(".claude-accounts/apple", org: "org-1", email: "old@x", tier: "default_claude_pro")
        let fresh = try makeDir(".claude-accounts/me@x", org: "org-1", email: "me@x", tier: "default_claude_max_20x")
        let creds = TokenTable()
        creds.expiry[stale] = Date(timeIntervalSince1970: 100)
        creds.expiry[fresh] = Date(timeIntervalSince1970: 200)
        let found = AccountDirectory(home: home.path, credentials: creds).scan()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].configDir, fresh)
        XCTAssertEqual(found[0].tier, "default_claude_max_20x", "the tier of the dir we actually fetch with")
        XCTAssertEqual(found[0].email, "me@x")
    }

    /// …but a primary dir written before `organizationRateLimitTier` existed must not
    /// erase a tier another dir of the same org still carries.
    func testTierFallsBackToAMemberThatStillCarriesOne() throws {
        let known = try makeDir(".claude-accounts/apple", org: "org-1", email: "me@x", tier: "default_claude_max_20x")
        let primary = try makeDir(".claude-accounts/me@x", org: "org-1", email: nil, tier: nil)
        let creds = TokenTable()
        creds.expiry[known] = Date(timeIntervalSince1970: 100)
        creds.expiry[primary] = Date(timeIntervalSince1970: 200)
        let found = AccountDirectory(home: home.path, credentials: creds).scan()
        XCTAssertEqual(found[0].configDir, primary)
        XCTAssertEqual(found[0].tier, "default_claude_max_20x")
        XCTAssertEqual(found[0].email, "me@x")
    }

    func testDedupKeepsFirstPositionInOrder() throws {
        try makeDir(".claude", org: "org-A")
        try makeDir(".claude-accounts/z", org: "org-B")
        let dup = try makeDir(".claude-accounts/a-dup-of-default", org: "org-A")
        let found = AccountDirectory(home: home.path, credentials: TokenTable()).scan()
        XCTAssertEqual(found.map(\.organizationUuid), ["org-A", "org-B"])
        XCTAssertEqual(found[0].aliasDirs, [dup])
    }
}
