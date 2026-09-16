import XCTest
@testable import GroveCore

final class OAuthUsageClientBackoffCapTests: XCTestCase {
    private final class Always429: UsageFetching, @unchecked Sendable {
        var calls = 0
        func fetch(_ request: URLRequest) async throws -> (Data, Int) { calls += 1; return (Data(), 429) }
    }
    private struct Creds: CredentialsReading {
        func token(configDir: String) -> ClaudeToken? { ClaudeToken(value: "t", expiresAt: nil) }
    }

    /// Brow polls every 60–120 s; an hour-long backoff would freeze it. The cap is
    /// injectable so Brow can pass 300 s while Grove keeps the default 3600 s.
    func testBackoffNeverExceedsInjectedCap() async {
        let fetcher = Always429()
        let client = OAuthUsageClient(fetcher: fetcher, appVersion: "x", cacheSeconds: 30,
                                      backoffCap: 300, credentials: Creds())
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // Drive attempts far enough that 30·2^n would exceed 300 s.
        var t = t0
        for _ in 0..<8 {
            _ = try? await client.usage(configDir: "d", now: t)
            t = t.addingTimeInterval(3600)   // step past whatever backoff was set
        }
        let before = fetcher.calls
        // Just under the cap after the last 429 → still suppressed.
        _ = try? await client.usage(configDir: "d", now: t.addingTimeInterval(-3600 + 299))
        XCTAssertEqual(fetcher.calls, before, "inside the 300 s cap the fetcher must not be hit")
        // At the cap → allowed again.
        _ = try? await client.usage(configDir: "d", now: t.addingTimeInterval(-3600 + 300))
        XCTAssertEqual(fetcher.calls, before + 1, "backoff must expire at exactly the injected cap")
    }

    func testDefaultCapIsOneHour() async {
        let fetcher = Always429()
        let client = OAuthUsageClient(fetcher: fetcher, appVersion: "x", cacheSeconds: 180, credentials: Creds())
        var t = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<8 { _ = try? await client.usage(configDir: "d", now: t); t = t.addingTimeInterval(7200) }
        let before = fetcher.calls
        _ = try? await client.usage(configDir: "d", now: t.addingTimeInterval(-7200 + 3599))
        XCTAssertEqual(fetcher.calls, before)
        _ = try? await client.usage(configDir: "d", now: t.addingTimeInterval(-7200 + 3600))
        XCTAssertEqual(fetcher.calls, before + 1)
    }
}
