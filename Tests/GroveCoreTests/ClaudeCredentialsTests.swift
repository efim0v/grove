import XCTest
@testable import GroveCore

final class ClaudeCredentialsTests: XCTestCase {
    typealias K = KeychainCredentialsReader

    // MARK: - service-name scheme (the reverse-engineered Keychain keying)

    func testDefaultAccountUsesBareService() {
        XCTAssertEqual(K.serviceName(configDir: NSHomeDirectory() + "/.claude"),
                       "Claude Code-credentials")
        // A tilde must expand to the same thing.
        XCTAssertEqual(K.serviceName(configDir: "~/.claude"), "Claude Code-credentials")
    }

    func testCustomAccountUsesSha256SuffixedService() {
        // Regression vector confirmed against a real install: the custom config dir
        // "/Users/demo/.claude-accounts/work-account" keys the Keychain item
        // "Claude Code-credentials-a0e8383e". This pins the exact scheme (first 8 hex
        // of sha256(expanded dir, no trailing slash)) so it can't silently drift.
        XCTAssertEqual(
            K.serviceName(configDir: "/Users/demo/.claude-accounts/work-account"),
            "Claude Code-credentials-a0e8383e")
    }

    func testTrailingSlashDoesNotChangeTheService() {
        XCTAssertEqual(
            K.serviceName(configDir: "/Users/demo/.claude-accounts/work-account/"),
            K.serviceName(configDir: "/Users/demo/.claude-accounts/work-account"))
    }

    // MARK: - CachingCredentialsReader (Keychain prompt minimization)

    /// A base reader that counts how many times the underlying (Keychain) read runs.
    private final class CountingReader: CredentialsReading, @unchecked Sendable {
        var calls: [String: Int] = [:]
        var token: String? = "tok"
        func accessToken(configDir: String) -> String? {
            calls[configDir, default: 0] += 1
            return token
        }
    }

    func testCachingReaderReadsBaseOncePerConfigDir() {
        let base = CountingReader()
        let caching = CachingCredentialsReader(base: base)
        // Repeated reads of the same account hit the base exactly once (one prompt).
        for _ in 0..<5 { XCTAssertEqual(caching.accessToken(configDir: "~/.claude"), "tok") }
        XCTAssertEqual(base.calls["~/.claude"], 1)
        _ = caching.accessToken(configDir: "~/.claude-accounts/a")
        XCTAssertEqual(base.calls["~/.claude-accounts/a"], 1)
    }

    func testCachingReaderInvalidateForcesReread() {
        let base = CountingReader()
        let caching = CachingCredentialsReader(base: base)
        _ = caching.accessToken(configDir: "~/.claude")
        caching.invalidate(configDir: "~/.claude")
        _ = caching.accessToken(configDir: "~/.claude")
        XCTAssertEqual(base.calls["~/.claude"], 2, "invalidate re-reads (e.g. after a refreshed token)")
    }

    /// A failed read is REMEMBERED for `nilReadFloor`, not retried on the next call:
    /// once the Keychain has refused, asking again only re-raises the same modal, and
    /// the poll cycle runs every 60 s. `invalidate` — called when the user may have
    /// just granted access — is what forces the retry, and it takes effect at once.
    /// (The floor's expiry is covered with an injected clock in `OAuthTokenExpiryTests`.)
    func testCachingReaderRemembersANilReadUntilInvalidated() {
        let base = CountingReader()
        base.token = nil   // first read fails (e.g. the user dismissed the prompt)
        let caching = CachingCredentialsReader(base: base)
        XCTAssertNil(caching.accessToken(configDir: "~/.claude"))

        base.token = "tok"
        XCTAssertNil(caching.accessToken(configDir: "~/.claude"),
                     "inside the floor the base must not be asked — that is the prompt we are avoiding")
        XCTAssertEqual(base.calls["~/.claude"], 1)

        caching.invalidate(configDir: "~/.claude")
        XCTAssertEqual(caching.accessToken(configDir: "~/.claude"), "tok",
                       "invalidate clears the nil record, so a granted credential is picked up at once")
        XCTAssertEqual(base.calls["~/.claude"], 2)
    }

    func testSuffixedServiceShapeForAnArbitraryDir() {
        let name = K.serviceName(configDir: "/tmp/some-account")
        XCTAssertTrue(name.hasPrefix("Claude Code-credentials-"))
        let suffix = name.dropFirst("Claude Code-credentials-".count)
        XCTAssertEqual(suffix.count, 8)
        XCTAssertTrue(suffix.allSatisfy { $0.isHexDigit })
    }

    // MARK: - token parsing (Keychain blob == legacy .credentials.json shape)

    func testParseTokenFromClaudeAiOauth() {
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"abc","refreshToken":"r"}}"#.utf8)
        XCTAssertEqual(K.parseToken(blob), "abc")
    }

    func testParseTokenFromTopLevel() {
        XCTAssertEqual(K.parseToken(Data(#"{"accessToken":"xyz"}"#.utf8)), "xyz")
    }

    func testParseTokenRejectsEmptyOrMissingOrMalformed() {
        XCTAssertNil(K.parseToken(Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)))
        XCTAssertNil(K.parseToken(Data(#"{"claudeAiOauth":{"nope":1}}"#.utf8)))
        XCTAssertNil(K.parseToken(Data("not json".utf8)))
    }

    // MARK: - file fallback (older installs)

    func testAccessTokenFallsBackToCredentialsFile() throws {
        let dir = try Fixture.tempDir("creds")
        try #"{"claudeAiOauth":{"accessToken":"file-tok"}}"#
            .write(to: dir.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        // The Keychain lookup for this unique temp path misses (no prompt), so the
        // reader falls back to the file.
        XCTAssertEqual(K().accessToken(configDir: dir.path), "file-tok")
    }

    func testAccessTokenNilWhenNothingAvailable() throws {
        let dir = try Fixture.tempDir("creds-empty")
        XCTAssertNil(K().accessToken(configDir: dir.path))
    }
}
