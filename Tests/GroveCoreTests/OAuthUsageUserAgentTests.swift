import XCTest
@testable import GroveCore

/// The spec's ToS mitigation, in writing: "Brow does not send a `claude-code/…`
/// User-Agent (verified unnecessary)". A third-party app must not identify itself as
/// Anthropic's own client, so the header is a per-client choice — Grove keeps it,
/// Brow omits it — and this pins both halves so code and spec cannot drift apart
/// again silently.
final class OAuthUsageUserAgentTests: XCTestCase {
    private final class HeaderSpy: UsageFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var header: String?
        private var count = 0
        var userAgent: String? { lock.withLock { header } }
        var calls: Int { lock.withLock { count } }
        func fetch(_ request: URLRequest) async throws -> (Data, Int) {
            lock.withLock {
                header = request.value(forHTTPHeaderField: "User-Agent")
                count += 1
            }
            return (Data(#"{"five_hour":{"utilization":10}}"#.utf8), 200)
        }
    }
    private struct Creds: CredentialsReading {
        func token(configDir: String) -> ClaudeToken? { ClaudeToken(value: "t", expiresAt: nil) }
    }

    func testAppVersionInitIdentifiesAsClaudeCode() async throws {
        let spy = HeaderSpy()
        let client = OAuthUsageClient(fetcher: spy, appVersion: "9.9.9", credentials: Creds())
        _ = try await client.usage(configDir: "/d", now: Date())
        XCTAssertEqual(spy.calls, 1)
        XCTAssertEqual(spy.userAgent, "claude-code/9.9.9")
    }

    func testNilUserAgentOmitsTheHeaderEntirely() async throws {
        let spy = HeaderSpy()
        let client = OAuthUsageClient(fetcher: spy, userAgent: nil, credentials: Creds())
        _ = try await client.usage(configDir: "/d", now: Date())
        XCTAssertEqual(spy.calls, 1)
        XCTAssertNil(spy.userAgent, "Brow sends no claude-code/… User-Agent (spec, Risks)")
    }
}
