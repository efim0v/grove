import XCTest
@testable import GroveCore

/// The panel's "Updated …" line must state when the limits were REALLY fetched, so
/// a 3-minute cache hit has to keep reporting its original fetch time rather than
/// the moment it was served. The refresh button needs the opposite lever: skip the
/// cache on demand — without ever skipping the 429 backoff.
final class OAuthUsageFreshnessTests: XCTestCase {
    private var configDir: URL!

    override func setUpWithError() throws {
        configDir = try Fixture.tempDir("oauth-freshness")
        try #"{"claudeAiOauth":{"accessToken":"tok-123"}}"#
            .write(to: configDir.appendingPathComponent(".credentials.json"),
                   atomically: true, encoding: .utf8)
    }

    private func okBody() -> Data {
        Data(#"{"five_hour":{"utilization":40,"resets_at":"2025-06-15T13:00:00Z"}}"#.utf8)
    }

    private final class CountingFetcher: UsageFetching, @unchecked Sendable {
        private(set) var count = 0
        let body: Data; let status: Int
        init(_ body: Data, status: Int = 200) { self.body = body; self.status = status }
        func fetch(_ request: URLRequest) async throws -> (Data, Int) {
            count += 1
            return (body, status)
        }
    }

    func testFreshFetchIsStampedWithTheFetchInstant() async throws {
        let client = OAuthUsageClient(fetcher: CountingFetcher(okBody()), appVersion: "x")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let usage = try await client.usage(configDir: configDir.path, now: t0)
        XCTAssertEqual(usage.fetchedAt, t0)
    }

    func testCacheHitKeepsTheOriginalFetchTime() async throws {
        let stub = CountingFetcher(okBody())
        let client = OAuthUsageClient(fetcher: stub, appVersion: "x")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = try await client.usage(configDir: configDir.path, now: t0)
        let cached = try await client.usage(configDir: configDir.path,
                                            now: t0.addingTimeInterval(120))
        XCTAssertEqual(stub.count, 1, "still inside the cache window")
        XCTAssertEqual(cached.fetchedAt, t0, "cached data must report when it was really fetched")
    }

    func testForceBypassesTheCache() async throws {
        let stub = CountingFetcher(okBody())
        let client = OAuthUsageClient(fetcher: stub, appVersion: "x")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = try await client.usage(configDir: configDir.path, now: t0)
        let forced = try await client.usage(configDir: configDir.path,
                                            now: t0.addingTimeInterval(10), force: true)
        XCTAssertEqual(stub.count, 2, "force refetches inside the cache window")
        XCTAssertEqual(forced.fetchedAt, t0.addingTimeInterval(10))
    }

    /// Hammering the refresh button must not defeat the rate-limit backoff.
    func testForceStillRespectsTheBackoffWindow() async throws {
        let stub = CountingFetcher(okBody(), status: 429)
        let client = OAuthUsageClient(fetcher: stub, appVersion: "x")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        await XCTAssertThrowsErrorAsync(try await client.usage(configDir: configDir.path, now: t0))
        await XCTAssertThrowsErrorAsync(
            try await client.usage(configDir: configDir.path,
                                   now: t0.addingTimeInterval(1), force: true))
        XCTAssertEqual(stub.count, 1, "force must not punch through the 429 backoff")
    }
}
