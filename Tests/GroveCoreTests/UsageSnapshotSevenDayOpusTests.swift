import XCTest
@testable import GroveCore

/// Phase 5C — tests that sevenDayOpus and sevenDayFable are plumbed through
/// UsageSnapshot and OAuthUsageClient. Written BEFORE the implementation (TDD RED).
final class UsageSnapshotSevenDayOpusTests: XCTestCase {
    private let fm = FileManager.default
    private var configDir: URL!
    private let reader = UsageReader()

    override func setUpWithError() throws {
        configDir = try Fixture.tempDir("usage-snapshot-opus")
    }

    private func writeSnapshot(_ rel: String, _ json: String) throws {
        let url = configDir.appendingPathComponent("grove/usage").appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - UsageSnapshot carries sevenDayOpus

    func testUsageSnapshotDefaultInitHasNilSevenDayOpus() {
        let snap = UsageSnapshot(accountName: "a", sessionId: "s", capturedAt: nil, cwd: nil,
                                 modelId: nil, modelDisplayName: nil, effort: nil,
                                 contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                                 fiveHour: nil, sevenDay: nil)
        // sevenDayOpus must exist as a field and default to nil
        XCTAssertNil(snap.sevenDayOpus)
    }

    func testUsageSnapshotDefaultInitHasNilSevenDayFable() {
        let snap = UsageSnapshot(accountName: "a", sessionId: "s", capturedAt: nil, cwd: nil,
                                 modelId: nil, modelDisplayName: nil, effort: nil,
                                 contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                                 fiveHour: nil, sevenDay: nil)
        // sevenDayFable must exist as a field and default to nil
        XCTAssertNil(snap.sevenDayFable)
    }

    func testUsageSnapshotExplicitSevenDayOpusIsPreserved() {
        let opus = CapturedWindow(usedPercentage: 42.0, resetsAt: "2026-07-15T00:00:00Z")
        let snap = UsageSnapshot(accountName: "a", sessionId: "s", capturedAt: nil, cwd: nil,
                                 modelId: nil, modelDisplayName: nil, effort: nil,
                                 contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                                 fiveHour: nil, sevenDay: nil, sevenDaySonnet: nil,
                                 sevenDayOpus: opus)
        XCTAssertEqual(snap.sevenDayOpus?.usedPercentage, 42.0)
        XCTAssertEqual(snap.sevenDayOpus?.resetsAt, "2026-07-15T00:00:00Z")
    }

    func testUsageSnapshotExplicitSevenDayFableIsPreserved() {
        let fable = CapturedWindow(usedPercentage: 18.0, resetsAt: "2026-07-15T00:00:00Z")
        let snap = UsageSnapshot(accountName: "a", sessionId: "s", capturedAt: nil, cwd: nil,
                                 modelId: nil, modelDisplayName: nil, effort: nil,
                                 contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                                 fiveHour: nil, sevenDay: nil, sevenDaySonnet: nil,
                                 sevenDayOpus: nil, sevenDayFable: fable)
        XCTAssertEqual(snap.sevenDayFable?.usedPercentage, 18.0)
    }

    // MARK: - OAuthUsage carries sevenDayFable

    func testOAuthUsageCarriesSevenDayFable() {
        let fable = OAuthWindow(utilization: 15.0, resetsAt: "2026-07-15T00:00:00Z")
        let usage = OAuthUsage(fiveHour: nil, sevenDay: nil, sevenDaySonnet: nil,
                               sevenDayOpus: nil, sevenDayFable: fable)
        XCTAssertEqual(usage.sevenDayFable?.utilization, 15.0)
    }

    // MARK: - OAuthUsageClient.parse picks up seven_day_opus and seven_day_fable

    func testOAuthClientParsesSeven_day_opus() async throws {
        let dir = try Fixture.tempDir("oauth-opus-parse")
        try #"{"claudeAiOauth":{"accessToken":"tok-x"}}"#
            .write(to: dir.appendingPathComponent(".credentials.json"),
                   atomically: true, encoding: .utf8)
        let body = Data(#"""
        {"five_hour":{"utilization":10,"resets_at":"2026-07-15T05:00:00Z"},
         "seven_day":{"utilization":5,"resets_at":"2026-07-19T00:00:00Z"},
         "seven_day_sonnet":{"utilization":8},
         "seven_day_opus":{"utilization":22,"resets_at":"2026-07-19T00:00:00Z"}}
        """#.utf8)
        let stub = StubFetcherP5C(.success((body, 200)))
        let client = OAuthUsageClient(fetcher: stub, appVersion: "test")
        let usage = try await client.usage(configDir: dir.path, now: Date())
        XCTAssertEqual(usage.sevenDayOpus?.utilization, 22.0)
        XCTAssertEqual(usage.sevenDayOpus?.resetsAt, "2026-07-19T00:00:00Z")
    }

    func testOAuthClientParsesSeven_day_fable_whenPresent() async throws {
        let dir = try Fixture.tempDir("oauth-fable-parse")
        try #"{"claudeAiOauth":{"accessToken":"tok-y"}}"#
            .write(to: dir.appendingPathComponent(".credentials.json"),
                   atomically: true, encoding: .utf8)
        // TODO: verify seven_day_fable key against a live payload
        let body = Data(#"""
        {"five_hour":{"utilization":5},
         "seven_day_fable":{"utilization":33,"resets_at":"2026-07-19T00:00:00Z"}}
        """#.utf8)
        let stub = StubFetcherP5C(.success((body, 200)))
        let client = OAuthUsageClient(fetcher: stub, appVersion: "test")
        let usage = try await client.usage(configDir: dir.path, now: Date())
        XCTAssertEqual(usage.sevenDayFable?.utilization, 33.0)
    }

    func testOAuthClientFableNilWhenAbsentFromPayload() async throws {
        let dir = try Fixture.tempDir("oauth-fable-absent")
        try #"{"claudeAiOauth":{"accessToken":"tok-z"}}"#
            .write(to: dir.appendingPathComponent(".credentials.json"),
                   atomically: true, encoding: .utf8)
        let body = Data(#"{"five_hour":{"utilization":10},"seven_day_opus":{"utilization":20}}"#.utf8)
        let stub = StubFetcherP5C(.success((body, 200)))
        let client = OAuthUsageClient(fetcher: stub, appVersion: "test")
        let usage = try await client.usage(configDir: dir.path, now: Date())
        XCTAssertNil(usage.sevenDayFable, "fable nil when key absent — degrades gracefully")
    }
}

/// Local stub fetcher (avoids collision with the one in OAuthUsageClientTests).
private final class StubFetcherP5C: UsageFetching, @unchecked Sendable {
    var result: Result<(Data, Int), Error>
    init(_ result: Result<(Data, Int), Error>) { self.result = result }
    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        switch result { case .success(let v): return v; case .failure(let e): throw e }
    }
}
