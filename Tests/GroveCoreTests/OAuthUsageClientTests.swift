import XCTest
@testable import GroveCore

final class OAuthUsageClientTests: XCTestCase {
    private let fm = FileManager.default
    private var configDir: URL!

    override func setUpWithError() throws {
        configDir = try Fixture.tempDir("oauth-usage")
        // .credentials.json with a bearer token (read, never sent anywhere real).
        try #"{"claudeAiOauth":{"accessToken":"tok-123"}}"#
            .write(to: configDir.appendingPathComponent(".credentials.json"),
                   atomically: true, encoding: .utf8)
    }

    /// A scripted fetcher: records the request it was handed and returns canned data.
    private final class StubFetcher: UsageFetching, @unchecked Sendable {
        var lastRequest: URLRequest?
        var result: Result<(Data, Int), Error>
        init(_ result: Result<(Data, Int), Error>) { self.result = result }
        func fetch(_ request: URLRequest) async throws -> (Data, Int) {
            lastRequest = request
            switch result { case .success(let v): return v; case .failure(let e): throw e }
        }
    }

    private func okBody() -> Data {
        Data(#"""
        {"five_hour":{"utilization":40,"resets_at":"2025-06-15T13:00:00Z"},
         "seven_day":{"utilization":12,"resets_at":"2025-06-20T00:00:00Z"},
         "seven_day_sonnet":{"utilization":8,"resets_at":"2025-06-20T00:00:00Z"},
         "seven_day_opus":{"utilization":20,"resets_at":"2025-06-20T00:00:00Z"}}
        """#.utf8)
    }

    func testSendsRequiredHeadersAndBearerFromCredentials() async throws {
        let stub = StubFetcher(.success((okBody(), 200)))
        let client = OAuthUsageClient(fetcher: stub, appVersion: "2.1.80")
        _ = try await client.usage(configDir: configDir.path, now: Date())
        let req = try XCTUnwrap(stub.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), "claude-code/2.1.80")
    }

    func testParsesAllWindows() async throws {
        let client = OAuthUsageClient(fetcher: StubFetcher(.success((okBody(), 200))), appVersion: "x")
        let usage = try await client.usage(configDir: configDir.path, now: Date())
        XCTAssertEqual(usage.fiveHour?.utilization, 40)
        XCTAssertEqual(usage.sevenDay?.utilization, 12)
        XCTAssertEqual(usage.sevenDaySonnet?.utilization, 8)
        XCTAssertEqual(usage.sevenDayOpus?.utilization, 20)
    }

    /// Within the cache window a SECOND call must NOT re-hit the fetcher.
    func testCachesForAtLeastThreeMinutes() async throws {
        let stub = CountingFetcher(okBody())
        let client = OAuthUsageClient(fetcher: stub, appVersion: "x")
        let t0 = Date()
        _ = try await client.usage(configDir: configDir.path, now: t0)
        _ = try await client.usage(configDir: configDir.path, now: t0.addingTimeInterval(120))   // 2m later
        XCTAssertEqual(stub.count, 1, "second call within 3min served from cache")
        _ = try await client.usage(configDir: configDir.path, now: t0.addingTimeInterval(200))   // >3m
        XCTAssertEqual(stub.count, 2, "after the cache window a new fetch happens")
    }

    /// A 429 backs off: the error surfaces and the next immediate call is throttled,
    /// not retried against the fetcher.
    func testBacksOffOnTooManyRequests() async throws {
        let stub = CountingFetcher(okBody(), status: 429)
        let client = OAuthUsageClient(fetcher: stub, appVersion: "x")
        let t0 = Date()
        await XCTAssertThrowsErrorAsync(try await client.usage(configDir: configDir.path, now: t0))
        // Immediately after a 429 the client backs off and does NOT call the fetcher again.
        await XCTAssertThrowsErrorAsync(try await client.usage(configDir: configDir.path,
                                                               now: t0.addingTimeInterval(1)))
        XCTAssertEqual(stub.count, 1, "the 429 backoff suppresses the immediate retry")
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
}

/// Tiny async throwing assertion helper (the suite has no XCTest async variant).
func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> some Any,
                              file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("expected an error", file: file, line: line) }
    catch { /* ok */ }
}
