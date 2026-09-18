import XCTest
@testable import GroveAppKit
import GroveCore

/// Phase 5C — tests for the modelWindow() helper that maps model-id prefix
/// → the right 7-day window and card title. Written BEFORE the implementation (TDD RED).
final class ModelWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let future: String = {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_750_000_000 + 86_400))
    }()

    private func snap(modelId: String?,
                      sevenDaySonnet: CapturedWindow? = nil,
                      sevenDayOpus: CapturedWindow? = nil,
                      sevenDayFable: CapturedWindow? = nil,
                      session: String = "s") -> UsageSnapshot {
        UsageSnapshot(accountName: "a", sessionId: session,
                      capturedAt: now, cwd: nil,
                      modelId: modelId, modelDisplayName: nil, effort: nil,
                      contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                      fiveHour: nil, sevenDay: nil,
                      sevenDaySonnet: sevenDaySonnet,
                      sevenDayOpus: sevenDayOpus,
                      sevenDayFable: sevenDayFable)
    }

    // MARK: - Opus family

    func testOpusModelIdReturnsWeeklyOpusTitle() {
        let opusWindow = CapturedWindow(usedPercentage: 30, resetsAt: future)
        let snapshots = [snap(modelId: "claude-opus-4-8", sevenDayOpus: opusWindow)]
        let result = modelWindow(latestModelId: "claude-opus-4-8", snapshots: snapshots, now: now)
        XCTAssertEqual(result.title, "Weekly Opus")
        XCTAssertEqual(result.window?.usedPercentage, 30)
    }

    func testOpus1MVariantIsRecognizedAsOpusFamily() {
        let opusWindow = CapturedWindow(usedPercentage: 50, resetsAt: future)
        let snapshots = [snap(modelId: "claude-opus-4-8[1m]", sevenDayOpus: opusWindow)]
        let result = modelWindow(latestModelId: "claude-opus-4-8[1m]", snapshots: snapshots, now: now)
        XCTAssertEqual(result.title, "Weekly Opus")
        XCTAssertEqual(result.window?.usedPercentage, 50)
    }

    func testOlderOpusVariantIsRecognizedAsOpusFamily() {
        let opusWindow = CapturedWindow(usedPercentage: 10, resetsAt: future)
        let snapshots = [snap(modelId: "claude-opus-4-7", sevenDayOpus: opusWindow)]
        let result = modelWindow(latestModelId: "claude-opus-4-7", snapshots: snapshots, now: now)
        XCTAssertEqual(result.title, "Weekly Opus")
        XCTAssertEqual(result.window?.usedPercentage, 10)
    }

    // MARK: - Sonnet family

    func testSonnetModelIdReturnsWeeklySonnetTitle() {
        let sonnetWindow = CapturedWindow(usedPercentage: 20, resetsAt: future)
        let snapshots = [snap(modelId: "claude-sonnet-4-6", sevenDaySonnet: sonnetWindow)]
        let result = modelWindow(latestModelId: "claude-sonnet-4-6", snapshots: snapshots, now: now)
        XCTAssertEqual(result.title, "Weekly Sonnet")
        XCTAssertEqual(result.window?.usedPercentage, 20)
    }

    // MARK: - Fable family

    func testFableModelIdReturnsWeeklyFableTitle() {
        let fableWindow = CapturedWindow(usedPercentage: 15, resetsAt: future)
        let snapshots = [snap(modelId: "claude-fable-5", sevenDayFable: fableWindow)]
        let result = modelWindow(latestModelId: "claude-fable-5", snapshots: snapshots, now: now)
        XCTAssertEqual(result.title, "Weekly Fable")
        // window present only when the API returned it; here it is
        XCTAssertEqual(result.window?.usedPercentage, 15)
    }

    func testFableWithNoAPIWindowIsNil() {
        // The API doesn't return seven_day_fable → sevenDayFable is nil → window is nil
        let snapshots = [snap(modelId: "claude-fable-5", sevenDayFable: nil)]
        let result = modelWindow(latestModelId: "claude-fable-5", snapshots: snapshots, now: now)
        XCTAssertEqual(result.title, "Weekly Fable")
        XCTAssertNil(result.window, "fable with no API data degrades to nil window")
    }

    // MARK: - Unknown / nil model id

    func testNilModelIdYieldsNilWindow() {
        let result = modelWindow(latestModelId: nil, snapshots: [], now: now)
        XCTAssertNil(result.window)
    }

    func testUnknownModelIdYieldsNilWindow() {
        let snapshots = [snap(modelId: "claude-haiku-3")]
        let result = modelWindow(latestModelId: "claude-haiku-3", snapshots: snapshots, now: now)
        XCTAssertNil(result.window, "unknown family → no window (hasData=false hides the card)")
    }

    // MARK: - accountDashboard builds weeklyModel card correctly

    func testAccountDashboardWeeklyModelTitleIsOpusWhenOpusModel() {
        let opusWindow = CapturedWindow(usedPercentage: 35, resetsAt: future)
        let snaps = [UsageSnapshot(accountName: "a", sessionId: "oauth",
                                   capturedAt: now, cwd: nil,
                                   modelId: nil, modelDisplayName: nil, effort: nil,
                                   contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                                   fiveHour: nil, sevenDay: nil,
                                   sevenDaySonnet: nil,
                                   sevenDayOpus: opusWindow),
                     // A statusline snapshot that declares the active model
                     UsageSnapshot(accountName: "a", sessionId: "s1",
                                   capturedAt: now.addingTimeInterval(-60), cwd: nil,
                                   modelId: "claude-opus-4-8", modelDisplayName: nil, effort: nil,
                                   contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                                   fiveHour: nil, sevenDay: nil)]
        let col = accountDashboard(name: "a", analytics: nil, snapshots: snaps, now: now)
        XCTAssertEqual(col.weeklyModels.map(\.title), ["Weekly Opus"])
        XCTAssertTrue(col.weeklyModels[0].hasData)
        XCTAssertEqual(col.weeklyModels[0].usedPercentage, 35, accuracy: 1e-9)
    }

    func testAccountDashboardWeeklyModelHiddenWhenNoData() {
        // No OAuth data → no model bar at all
        let col = accountDashboard(name: "a", analytics: nil, snapshots: [], now: now)
        XCTAssertTrue(col.weeklyModels.isEmpty)
    }

    func testAccountDashboardWeeklyModelSonnetWhenSonnetModel() {
        let sonnetWindow = CapturedWindow(usedPercentage: 12, resetsAt: future)
        let snaps = [UsageSnapshot(accountName: "a", sessionId: "oauth",
                                   capturedAt: now, cwd: nil,
                                   modelId: nil, modelDisplayName: nil, effort: nil,
                                   contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                                   fiveHour: nil, sevenDay: nil,
                                   sevenDaySonnet: sonnetWindow),
                     UsageSnapshot(accountName: "a", sessionId: "s2",
                                   capturedAt: now.addingTimeInterval(-30), cwd: nil,
                                   modelId: "claude-sonnet-4-6", modelDisplayName: nil, effort: nil,
                                   contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                                   fiveHour: nil, sevenDay: nil)]
        let col = accountDashboard(name: "a", analytics: nil, snapshots: snaps, now: now)
        XCTAssertEqual(col.weeklyModels.map(\.title), ["Weekly Sonnet"])
        XCTAssertEqual(col.weeklyModels[0].usedPercentage, 12, accuracy: 1e-9)
    }
}
