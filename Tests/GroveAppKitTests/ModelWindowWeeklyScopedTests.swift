import XCTest
@testable import GroveAppKit
import GroveCore

/// Phase 5C-fix — modelWindow() must prefer weeklyScoped data from the OAuth
/// snapshot (via UsageSnapshot.weeklyScopedWindow/weeklyScopedModel) over the
/// old per-model fields, and the title should come from the model display name.
/// Written BEFORE the implementation (TDD RED).
final class ModelWindowWeeklyScopedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_752_000_000)
    private let future: String = {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_752_000_000 + 86_400))
    }()

    // MARK: - weeklyScoped is used when present

    func testModelWindowPrefersScopedFableWindow() throws {
        let scopedWindow = CapturedWindow(usedPercentage: 100, resetsAt: future)
        let oauthSnap = UsageSnapshot(accountName: "a", sessionId: "oauth",
                                      capturedAt: now, cwd: nil,
                                      modelId: nil, modelDisplayName: nil, effort: nil,
                                      contextUsedPercentage: nil, totalInputTokens: nil,
                                      totalCostUSD: nil,
                                      fiveHour: nil, sevenDay: nil,
                                      weeklyScopedWindow: scopedWindow,
                                      weeklyScopedModel: "Fable")
        let result = modelWindow(latestModelId: nil, snapshots: [oauthSnap], now: now)
        XCTAssertEqual(result.title, "Weekly Fable")
        XCTAssertEqual(try XCTUnwrap(result.window).usedPercentage, 100, accuracy: 1e-9)
    }

    func testModelWindowPrefersScopedOpusWindow() throws {
        let scopedWindow = CapturedWindow(usedPercentage: 55, resetsAt: future)
        let oauthSnap = UsageSnapshot(accountName: "a", sessionId: "oauth",
                                      capturedAt: now, cwd: nil,
                                      modelId: nil, modelDisplayName: nil, effort: nil,
                                      contextUsedPercentage: nil, totalInputTokens: nil,
                                      totalCostUSD: nil,
                                      fiveHour: nil, sevenDay: nil,
                                      weeklyScopedWindow: scopedWindow,
                                      weeklyScopedModel: "Opus")
        let result = modelWindow(latestModelId: nil, snapshots: [oauthSnap], now: now)
        XCTAssertEqual(result.title, "Weekly Opus")
        XCTAssertEqual(try XCTUnwrap(result.window).usedPercentage, 55, accuracy: 1e-9)
    }

    func testModelWindowPrefersScopedWindowOverOldModelIdLookup() throws {
        // When weeklyScoped is present, it should take priority over the old
        // sevenDayFable/sevenDayOpus fields keyed off modelId prefix.
        let scopedWindow = CapturedWindow(usedPercentage: 100, resetsAt: future)
        let oldFableWindow = CapturedWindow(usedPercentage: 30, resetsAt: future)
        let oauthSnap = UsageSnapshot(accountName: "a", sessionId: "oauth",
                                      capturedAt: now, cwd: nil,
                                      modelId: nil, modelDisplayName: nil, effort: nil,
                                      contextUsedPercentage: nil, totalInputTokens: nil,
                                      totalCostUSD: nil,
                                      fiveHour: nil, sevenDay: nil,
                                      sevenDayFable: oldFableWindow,
                                      weeklyScopedWindow: scopedWindow,
                                      weeklyScopedModel: "Fable")
        let statusSnap = UsageSnapshot(accountName: "a", sessionId: "s1",
                                       capturedAt: now.addingTimeInterval(-60), cwd: nil,
                                       modelId: "claude-fable-5", modelDisplayName: nil, effort: nil,
                                       contextUsedPercentage: nil, totalInputTokens: nil,
                                       totalCostUSD: nil,
                                       fiveHour: nil, sevenDay: nil)
        let result = modelWindow(latestModelId: "claude-fable-5",
                                 snapshots: [oauthSnap, statusSnap], now: now)
        XCTAssertEqual(result.title, "Weekly Fable")
        // weeklyScoped (100%) takes priority over sevenDayFable (30%)
        XCTAssertEqual(try XCTUnwrap(result.window).usedPercentage, 100, accuracy: 1e-9,
                       "weeklyScoped window must override old sevenDayFable field")
    }

    // MARK: - hasData is false when no scoped window

    func testModelWindowHiddenWhenNoScopedWindow() {
        // No OAuth scoped window, no model id → hidden (hasData=false)
        let col = accountDashboard(name: "a", analytics: nil, snapshots: [], now: now)
        XCTAssertTrue(col.weeklyModels.isEmpty)
    }

    // MARK: - accountDashboard picks up weeklyScoped from OAuth snapshot

    func testAccountDashboardShowsFableScopedFromOAuth() {
        let scopedWindow = CapturedWindow(usedPercentage: 100, resetsAt: future)
        let oauthSnap = UsageSnapshot(accountName: "a", sessionId: "oauth",
                                      capturedAt: now, cwd: nil,
                                      modelId: nil, modelDisplayName: nil, effort: nil,
                                      contextUsedPercentage: nil, totalInputTokens: nil,
                                      totalCostUSD: nil,
                                      fiveHour: nil, sevenDay: nil,
                                      weeklyScopedWindow: scopedWindow,
                                      weeklyScopedModel: "Fable")
        let col = accountDashboard(name: "a", analytics: nil, snapshots: [oauthSnap], now: now)
        XCTAssertEqual(col.weeklyModels.map(\.title), ["Weekly Fable"])
        XCTAssertTrue(col.weeklyModels[0].hasData)
        XCTAssertEqual(col.weeklyModels[0].usedPercentage, 100, accuracy: 1e-9)
    }
}
