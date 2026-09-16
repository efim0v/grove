import XCTest
@testable import GroveCore

/// Regression suite for the "limits freeze after ~8h of uptime" bug.
///
/// Claude Code's OAuth access token is short-lived (the Keychain blob carries an
/// `expiresAt`, ~8h out) and Claude Code rotates it on its own cadence. Grove cached
/// the token for the WHOLE process lifetime with no expiry check and no invalidation
/// call site, so a long-running menu bar app kept presenting a token that had expired
/// days earlier. Every `api/oauth/usage` request then answered 401, the error was
/// swallowed, and the panel showed the last good capture forever — including when the
/// user pressed Refresh.
final class OAuthTokenExpiryTests: XCTestCase {
    typealias K = KeychainCredentialsReader

    /// A base reader that counts reads and can hand out a different token each time,
    /// exactly like the Keychain does after Claude Code rotates the credential.
    private final class RotatingReader: CredentialsReading, @unchecked Sendable {
        var calls: [String: Int] = [:]
        var next: ClaudeToken?
        init(_ token: ClaudeToken?) { self.next = token }
        func token(configDir: String) -> ClaudeToken? {
            calls[configDir, default: 0] += 1
            return next
        }
    }

    // MARK: - the token carries its own expiry

    func testKeychainReaderParsesExpiresAt() {
        // Claude Code stores expiresAt as epoch MILLISECONDS.
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"abc","expiresAt":1789015851603}}"#.utf8)
        let token = K.parseClaudeToken(blob)
        XCTAssertEqual(token?.value, "abc")
        XCTAssertEqual(token?.expiresAt?.timeIntervalSince1970 ?? 0, 1789015851.603, accuracy: 0.01)
    }

    func testKeychainReaderTolerartesMissingExpiry() {
        // Older installs / the legacy file may omit it: nil means "unknown lifetime",
        // which must NOT be read as "already expired".
        let token = K.parseClaudeToken(Data(#"{"claudeAiOauth":{"accessToken":"abc"}}"#.utf8))
        XCTAssertEqual(token?.value, "abc")
        XCTAssertNil(token?.expiresAt)
    }

    // MARK: - the cache honours that expiry

    func testCachedTokenIsRereadOnceItExpires() {
        let t0 = Date()
        let base = RotatingReader(ClaudeToken(value: "old", expiresAt: t0.addingTimeInterval(3600)))
        var clock = t0
        let caching = CachingCredentialsReader(base: base, now: { clock })

        XCTAssertEqual(caching.accessToken(configDir: "~/.claude"), "old")
        clock = t0.addingTimeInterval(1800)          // still inside the token's life
        XCTAssertEqual(caching.accessToken(configDir: "~/.claude"), "old")
        XCTAssertEqual(base.calls["~/.claude"], 1, "a live token must not re-prompt the Keychain")

        // Claude Code rotates the credential; Grove's cached copy is now past expiry.
        base.next = ClaudeToken(value: "new", expiresAt: t0.addingTimeInterval(3600 * 9))
        clock = t0.addingTimeInterval(3601)
        XCTAssertEqual(caching.accessToken(configDir: "~/.claude"), "new",
                       "an expired cached token must be re-read, not served forever")
        XCTAssertEqual(base.calls["~/.claude"], 2)
    }

    func testExpiryUsesSafetySkewSoTheTokenIsNeverSentOnItsLastBreath() {
        let t0 = Date()
        let base = RotatingReader(ClaudeToken(value: "old", expiresAt: t0.addingTimeInterval(30)))
        var clock = t0
        let caching = CachingCredentialsReader(base: base, now: { clock })
        _ = caching.accessToken(configDir: "~/.claude")
        base.next = ClaudeToken(value: "new", expiresAt: t0.addingTimeInterval(3600))
        clock = t0.addingTimeInterval(1)   // 29s of life left — inside the 60s skew
        XCTAssertEqual(caching.accessToken(configDir: "~/.claude"), "new",
                       "a token about to expire must be refreshed before it is used")
    }

    func testTokenWithoutExpiryIsStillCachedForTheProcess() {
        let base = RotatingReader(ClaudeToken(value: "tok", expiresAt: nil))
        let caching = CachingCredentialsReader(base: base, now: { Date() })
        for _ in 0..<3 { XCTAssertEqual(caching.accessToken(configDir: "~/.claude"), "tok") }
        XCTAssertEqual(base.calls["~/.claude"], 1, "unknown lifetime keeps the old prompt-once behaviour")
    }

    // MARK: - defense in depth: a 401 re-reads the credential and retries once

    /// Credentials that hand out a stale token until `invalidate` is called.
    private final class StaleThenFreshCredentials: CredentialsReading, @unchecked Sendable {
        var invalidations = 0
        private var rotated = false
        func token(configDir: String) -> ClaudeToken? {
            ClaudeToken(value: rotated ? "fresh" : "stale", expiresAt: nil)
        }
        func invalidate(configDir: String) { invalidations += 1; rotated = true }
    }

    /// Answers 401 to the stale bearer and 200 to the fresh one — the real endpoint's
    /// behaviour for an expired access token.
    private final class AuthAwareFetcher: UsageFetching, @unchecked Sendable {
        var bearers: [String] = []
        let body: Data
        init(body: Data) { self.body = body }
        func fetch(_ request: URLRequest) async throws -> (Data, Int) {
            let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
            bearers.append(bearer)
            return bearer == "Bearer fresh" ? (body, 200) : (Data("{}".utf8), 401)
        }
    }

    private func okBody() -> Data {
        Data(#"{"five_hour":{"utilization":8,"resets_at":"2026-09-10T01:50:00Z"}}"#.utf8)
    }

    func testUnauthorizedInvalidatesTheCachedTokenAndRetriesOnce() async throws {
        let creds = StaleThenFreshCredentials()
        let fetcher = AuthAwareFetcher(body: okBody())
        let client = OAuthUsageClient(fetcher: fetcher, appVersion: "x", credentials: creds)

        let usage = try await client.usage(configDir: "~/.claude", now: Date())

        XCTAssertEqual(usage.fiveHour?.utilization, 8, "the retry with a fresh token must succeed")
        XCTAssertEqual(creds.invalidations, 1, "a 401 must drop the cached token")
        XCTAssertEqual(fetcher.bearers, ["Bearer stale", "Bearer fresh"],
                       "exactly one retry, with the re-read credential")
    }

    /// Credentials whose re-read yields the same dead token — the retry must not loop.
    private final class AlwaysStaleCredentials: CredentialsReading, @unchecked Sendable {
        var invalidations = 0
        func token(configDir: String) -> ClaudeToken? { ClaudeToken(value: "stale", expiresAt: nil) }
        func invalidate(configDir: String) { invalidations += 1 }
    }

    func testUnauthorizedRetriesAtMostOnce() async {
        let creds = AlwaysStaleCredentials()
        let fetcher = AuthAwareFetcher(body: okBody())
        let client = OAuthUsageClient(fetcher: fetcher, appVersion: "x", credentials: creds)

        do {
            _ = try await client.usage(configDir: "~/.claude", now: Date())
            XCTFail("a persistently invalid token must surface as an error, not hang or loop")
        } catch {
            XCTAssertEqual(error as? OAuthUsageError, .http(401))
        }
        XCTAssertEqual(fetcher.bearers.count, 2, "one original attempt plus one retry — no more")
        XCTAssertEqual(creds.invalidations, 1)
    }
}
