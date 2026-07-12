import XCTest
@testable import GroveCore

/// Phase 5C-fix — tests that OAuthUsageClient.parse reads the `limits[]` array
/// for per-model scoped windows. Written BEFORE the implementation (TDD RED).
final class OAuthUsageLimitsArrayTests: XCTestCase {

    // MARK: - Fixture: live oauth-usage-live-sample.json

    /// This is the exact JSON captured live from Anthropic's API.
    /// fiveHour.utilization == 8, sevenDay.utilization == 86,
    /// weeklyScoped: percent 100, model "Fable", sevenDayOpus == nil.
    private static let liveSampleJSON = """
    {
        "five_hour": {
            "utilization": 8.0,
            "resets_at": "2026-07-12T13:39:59.725353+00:00"
        },
        "seven_day": {
            "utilization": 86.0,
            "resets_at": "2026-07-12T20:00:00.725374+00:00"
        },
        "seven_day_oauth_apps": null,
        "seven_day_opus": null,
        "seven_day_sonnet": null,
        "seven_day_cowork": null,
        "limits": [
            {
                "kind": "session",
                "group": "session",
                "percent": 8,
                "severity": "normal",
                "resets_at": "2026-07-12T13:39:59.725353+00:00",
                "scope": null,
                "is_active": false
            },
            {
                "kind": "weekly_all",
                "group": "weekly",
                "percent": 86,
                "severity": "warning",
                "resets_at": "2026-07-12T20:00:00.725374+00:00",
                "scope": null,
                "is_active": false
            },
            {
                "kind": "weekly_scoped",
                "group": "weekly",
                "percent": 100,
                "severity": "critical",
                "resets_at": "2026-07-12T19:59:59.725684+00:00",
                "scope": {
                    "model": {
                        "id": null,
                        "display_name": "Fable"
                    },
                    "surface": null
                },
                "is_active": true
            }
        ]
    }
    """

    private var configDir: URL!

    override func setUpWithError() throws {
        configDir = try Fixture.tempDir("oauth-limits-array")
        try #"{"claudeAiOauth":{"accessToken":"tok-fixture"}}"#
            .write(to: configDir.appendingPathComponent(".credentials.json"),
                   atomically: true, encoding: .utf8)
    }

    // MARK: - Load-bearing: parse against the real fixture schema

    func testLiveSampleParsesWeeklyScopedFable() async throws {
        let body = Data(Self.liveSampleJSON.utf8)
        let stub = StubFetcherLimits(.success((body, 200)))
        let client = OAuthUsageClient(fetcher: stub, appVersion: "test")
        let usage = try await client.usage(configDir: configDir.path, now: Date())

        // Top-level windows still parse correctly.
        XCTAssertEqual(try XCTUnwrap(usage.fiveHour).utilization, 8, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(usage.sevenDay).utilization, 86, accuracy: 1e-9)

        // The load-bearing assertion: weeklyScoped is derived from limits[].
        let scoped = try XCTUnwrap(usage.weeklyScoped, "weeklyScoped must be populated from limits[]")
        XCTAssertEqual(scoped.utilization, 100, accuracy: 1e-9)
        XCTAssertEqual(scoped.modelDisplayName, "Fable")
        XCTAssertEqual(scoped.resetsAt, "2026-07-12T19:59:59.725684+00:00")

        // Per-model top-level keys are null in this payload.
        XCTAssertNil(usage.sevenDayOpus, "sevenDayOpus null in live payload")
        XCTAssertNil(usage.sevenDaySonnet, "sevenDaySonnet null in live payload")
    }

    func testWeeklyScopedIsNilWhenNoLimitsArray() async throws {
        let body = Data("""
        {"five_hour":{"utilization":10,"resets_at":"2026-07-15T05:00:00Z"},
         "seven_day":{"utilization":5}}
        """.utf8)
        let stub = StubFetcherLimits(.success((body, 200)))
        let client = OAuthUsageClient(fetcher: stub, appVersion: "test")
        let usage = try await client.usage(configDir: configDir.path, now: Date())
        XCTAssertNil(usage.weeklyScoped, "no limits[] → weeklyScoped nil")
    }

    func testWeeklyScopedPrefersIsActiveEntry() async throws {
        let body = Data("""
        {"five_hour":{"utilization":10},
         "limits":[
           {"kind":"weekly_scoped","percent":50,"severity":"normal",
            "resets_at":"2026-07-19T00:00:00Z",
            "scope":{"model":{"id":null,"display_name":"Opus"},"surface":null},
            "is_active":false,"group":"weekly"},
           {"kind":"weekly_scoped","percent":90,"severity":"warning",
            "resets_at":"2026-07-19T01:00:00Z",
            "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},
            "is_active":true,"group":"weekly"}
         ]}
        """.utf8)
        let stub = StubFetcherLimits(.success((body, 200)))
        let client = OAuthUsageClient(fetcher: stub, appVersion: "test")
        let usage = try await client.usage(configDir: configDir.path, now: Date())
        let scoped2 = try XCTUnwrap(usage.weeklyScoped)
        XCTAssertEqual(scoped2.modelDisplayName, "Fable",
                       "is_active:true entry is preferred when multiple weekly_scoped entries exist")
        XCTAssertEqual(scoped2.utilization, 90, accuracy: 1e-9)
    }
}

/// Phase 5C-fix: tests for OAuthScopedWindow struct existing on OAuthUsage.
final class OAuthScopedWindowStructTests: XCTestCase {
    func testOAuthScopedWindowIsEquatable() {
        let a = OAuthScopedWindow(utilization: 100, resetsAt: "2026-07-12T19:59:59Z", modelDisplayName: "Fable")
        let b = OAuthScopedWindow(utilization: 100, resetsAt: "2026-07-12T19:59:59Z", modelDisplayName: "Fable")
        XCTAssertEqual(a, b)
    }

    func testOAuthUsageCarriesWeeklyScoped() {
        let scoped = OAuthScopedWindow(utilization: 75, resetsAt: nil, modelDisplayName: "Opus")
        let usage = OAuthUsage(fiveHour: nil, sevenDay: nil, sevenDaySonnet: nil,
                               sevenDayOpus: nil, sevenDayFable: nil, weeklyScoped: scoped)
        XCTAssertEqual(usage.weeklyScoped?.utilization, 75)
        XCTAssertEqual(usage.weeklyScoped?.modelDisplayName, "Opus")
    }

    func testOAuthUsageDefaultWeeklyScopedIsNil() {
        // Back-compat: existing callers that don't pass weeklyScoped get nil.
        let usage = OAuthUsage(fiveHour: nil, sevenDay: nil, sevenDaySonnet: nil,
                               sevenDayOpus: nil, sevenDayFable: nil)
        XCTAssertNil(usage.weeklyScoped)
    }
}

/// Phase 5C-fix: UsageSnapshot must carry weeklyScopedWindow + weeklyScopedModel.
final class UsageSnapshotWeeklyScopedTests: XCTestCase {
    func testUsageSnapshotDefaultHasNilWeeklyScopedFields() {
        let snap = UsageSnapshot(accountName: "a", sessionId: "s", capturedAt: nil, cwd: nil,
                                 modelId: nil, modelDisplayName: nil, effort: nil,
                                 contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                                 fiveHour: nil, sevenDay: nil)
        XCTAssertNil(snap.weeklyScopedWindow)
        XCTAssertNil(snap.weeklyScopedModel)
    }

    func testUsageSnapshotPreservesWeeklyScopedFields() {
        let w = CapturedWindow(usedPercentage: 100, resetsAt: "2026-07-12T19:59:59Z")
        let snap = UsageSnapshot(accountName: "a", sessionId: "oauth", capturedAt: nil, cwd: nil,
                                 modelId: nil, modelDisplayName: nil, effort: nil,
                                 contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                                 fiveHour: nil, sevenDay: nil,
                                 weeklyScopedWindow: w, weeklyScopedModel: "Fable")
        XCTAssertEqual(snap.weeklyScopedWindow?.usedPercentage, 100)
        XCTAssertEqual(snap.weeklyScopedModel, "Fable")
    }
}

private final class StubFetcherLimits: UsageFetching, @unchecked Sendable {
    var result: Result<(Data, Int), Error>
    init(_ result: Result<(Data, Int), Error>) { self.result = result }
    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        switch result { case .success(let v): return v; case .failure(let e): throw e }
    }
}
