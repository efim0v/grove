import XCTest
@testable import GroveCore

private final class StubFetcher: UsageFetching, @unchecked Sendable {
    var body: Data
    var status: Int
    var thrown: Error?
    private(set) var calls = 0
    init(body: Data = Data("{}".utf8), status: Int = 200, thrown: Error? = nil) {
        self.body = body; self.status = status; self.thrown = thrown
    }
    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        if let thrown { throw thrown }
        return (body, status)
    }
}

final class OAuthUsageClientGapTests: XCTestCase {
    private let fm = FileManager.default
    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    override func setUpWithError() throws { dir = try Fixture.tempDir("oauth-gap") }

    private func writeCredentials(_ json: String) throws {
        try json.write(to: dir.appendingPathComponent(".credentials.json"),
                       atomically: true, encoding: .utf8)
    }

    func testNoCredentialsWhenFileMissing() async {
        let client = OAuthUsageClient(fetcher: StubFetcher(), appVersion: "1.0")
        await assertThrows(OAuthUsageError.noCredentials) {
            _ = try await client.usage(configDir: dir.path, now: now)
        }
    }

    func testNoCredentialsWhenTokenAbsent() async throws {
        try writeCredentials(#"{"claudeAiOauth":{"somethingElse":1}}"#)
        let client = OAuthUsageClient(fetcher: StubFetcher(), appVersion: "1.0")
        await assertThrows(OAuthUsageError.noCredentials) {
            _ = try await client.usage(configDir: dir.path, now: now)
        }
    }

    func testTopLevelAccessTokenIsAccepted() async throws {
        try writeCredentials(#"{"accessToken":"tok"}"#)
        let fetcher = StubFetcher(body: Data(#"{"five_hour":{"utilization":12}}"#.utf8), status: 200)
        let client = OAuthUsageClient(fetcher: fetcher, appVersion: "1.0")
        let usage = try await client.usage(configDir: dir.path, now: now)
        XCTAssertEqual(usage.fiveHour?.utilization, 12)
        XCTAssertEqual(fetcher.calls, 1)
    }

    func testHttpErrorSurfacesStatus() async throws {
        try writeCredentials(#"{"accessToken":"tok"}"#)
        let client = OAuthUsageClient(fetcher: StubFetcher(status: 500), appVersion: "1.0")
        await assertThrows(OAuthUsageError.http(500)) {
            _ = try await client.usage(configDir: dir.path, now: now)
        }
    }

    func testMalformedBodyThrows() async throws {
        try writeCredentials(#"{"accessToken":"tok"}"#)
        let client = OAuthUsageClient(fetcher: StubFetcher(body: Data("not json".utf8), status: 200),
                                      appVersion: "1.0")
        await assertThrows(OAuthUsageError.malformed) {
            _ = try await client.usage(configDir: dir.path, now: now)
        }
    }

    func testBackoffSuppressesSecondCallWithoutFetching() async throws {
        try writeCredentials(#"{"accessToken":"tok"}"#)
        let fetcher = StubFetcher(status: 429)
        let client = OAuthUsageClient(fetcher: fetcher, appVersion: "1.0", cacheSeconds: 180)
        await assertThrows(OAuthUsageError.tooManyRequests) {
            _ = try await client.usage(configDir: dir.path, now: now)
        }
        // Within the backoff window -> .backoff, and the fetcher is NOT called again.
        await assertThrows(OAuthUsageError.backoff) {
            _ = try await client.usage(configDir: dir.path, now: now.addingTimeInterval(10))
        }
        XCTAssertEqual(fetcher.calls, 1)
    }

    func testParsesIntUtilizationAndIgnoresMissingWindows() async throws {
        try writeCredentials(#"{"accessToken":"tok"}"#)
        // utilization as an Int; seven_day missing entirely; sonnet present.
        let body = #"{"five_hour":{"utilization":7,"resets_at":"2025-06-16T00:00:00Z"},"seven_day_sonnet":{"utilization":3}}"#
        let client = OAuthUsageClient(fetcher: StubFetcher(body: Data(body.utf8), status: 200),
                                      appVersion: "1.0")
        let usage = try await client.usage(configDir: dir.path, now: now)
        XCTAssertEqual(usage.fiveHour?.utilization, 7)
        XCTAssertEqual(usage.fiveHour?.resetsAt, "2025-06-16T00:00:00Z")
        XCTAssertNil(usage.sevenDay)
        XCTAssertEqual(usage.sevenDaySonnet?.utilization, 3)
    }

    private func assertThrows(_ expected: OAuthUsageError, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("expected \(expected)") }
        catch let error as OAuthUsageError { XCTAssertEqual(error, expected) }
        catch { XCTFail("unexpected error \(error)") }
    }
}
