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

    /// A base reader that parks inside the read, exactly as `SecItemCopyMatching` parks
    /// behind a modal prompt: the caller's thread is held and the cache cannot possibly
    /// have been filled, because nothing has returned.
    private final class BlockingReader: CredentialsReading, @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }

        func accessToken(configDir: String) -> String? {
            lock.withLock { count += 1 }
            entered.signal()
            release.wait()
            return "tok"
        }
        func waitUntilInside() { entered.wait() }
        func letGo() { release.signal() }
    }

    /// Single-flight per config dir. The cache cannot dedupe two SIMULTANEOUS reads — it
    /// is filled when a read RETURNS, and a read parked on a modal prompt has not
    /// returned — so the Brow cycle's account scan, `TokenKeeper.ensureFresh` and the
    /// usage fetch could each raise their own prompt for the same Keychain item. That is
    /// the multi-prompt first run the store's single-flight discovery exists to prevent,
    /// reachable around it: the 5 s Keychain patience releases the cycle to fetch for the
    /// SEEDED accounts while the scan is still parked on those very items.
    func testTwoConcurrentReadsOfOneDirAskTheKeychainOnce() {
        let base = BlockingReader()
        let caching = CachingCredentialsReader(base: base)
        let done = expectation(description: "both reads answered")
        done.expectedFulfillmentCount = 2

        let first = Thread {
            XCTAssertEqual(caching.accessToken(configDir: "~/.claude"), "tok")
            done.fulfill()
        }
        first.start()
        base.waitUntilInside()                  // the first read is parked in the "prompt"

        let second = Thread {
            XCTAssertEqual(caching.accessToken(configDir: "~/.claude"), "tok",
                           "the second caller gets the first one's answer")
            done.fulfill()
        }
        second.start()
        // Give the second thread time to reach the gate and (under the old code) to
        // raise its own prompt.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(base.calls, 1, "one Keychain read, one prompt")

        base.letGo()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(base.calls, 1, "and still one after both callers are served")
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
