import XCTest
@testable import GroveAppKit
import GroveCore

final class DashboardPresentationTests: XCTestCase {
    // 2025-06-15T16:53:20Z (UTC) — same instant family as the analytics tests.
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func snap(captured: Date?, five: CapturedWindow?, seven: CapturedWindow? = nil,
                      session: String = "s") -> UsageSnapshot {
        UsageSnapshot(accountName: "a", sessionId: session, capturedAt: captured, cwd: nil,
                      modelId: nil, modelDisplayName: nil, effort: nil,
                      contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                      fiveHour: five, sevenDay: seven)
    }

    // MARK: - formatters

    func testCompactTokenFormatting() {
        XCTAssertEqual(formatCompactTokens(999), "999")
        XCTAssertEqual(formatCompactTokens(1_500), "1.5k")
        XCTAssertEqual(formatCompactTokens(3_000_000), "3M")
        XCTAssertEqual(formatCompactTokens(3_900_000), "3.9M")
        XCTAssertEqual(formatCompactTokens(5_900_000_000), "5.9B")
    }

    func testCompactCostFormatting() {
        XCTAssertEqual(formatCompactCost(0), "$0")
        XCTAssertEqual(formatCompactCost(7.7), "$7.70")
        XCTAssertEqual(formatCompactCost(3_400), "$3.4k")
    }

    // MARK: - LimitCard

    func testLimitCardNoDataIsNeutral() {
        let card = LimitCard(window: .fiveHour, title: "5h", systemImage: "clock",
                             usedPercentage: 0, resetsAt: nil, hasData: false, now: now)
        XCTAssertEqual(card.level, .noData)
        XCTAssertEqual(card.usedPercentage, 0)
        XCTAssertEqual(card.note, "no data")
        XCTAssertFalse(card.noteIsWarning)
        XCTAssertEqual(card.resetCaption, "")
    }

    func testLimitCardCriticalWhenNearlyFull() {
        let card = LimitCard(window: .weekly, title: "Weekly", systemImage: "calendar",
                             usedPercentage: 96, resetsAt: nil, hasData: true, now: now)
        XCTAssertEqual(card.level, .critical)
        XCTAssertEqual(card.note, "limit close")
        XCTAssertTrue(card.noteIsWarning)
    }

    func testLimitCardOnTrackWhenPlenty() {
        let card = LimitCard(window: .fiveHour, title: "5h", systemImage: "clock",
                             usedPercentage: 30, resetsAt: nil, hasData: true, now: now)
        XCTAssertEqual(card.level, .plenty)
        XCTAssertEqual(card.note, "On track")
    }

    func testLimitCardCountdownFormats() {
        XCTAssertEqual(LimitCard.shortCountdown(90_000), "1d 1h")
        XCTAssertEqual(LimitCard.shortCountdown(3 * 3600 + 58 * 60), "3h 58m")
        XCTAssertEqual(LimitCard.shortCountdown(12 * 60), "12m")
        XCTAssertEqual(LimitCard.shortCountdown(-5), "resetting…")
    }

    func testLimitCardResetCaptionFromFutureDate() {
        let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(2 * 86_400 + 3_600))
        let card = LimitCard(window: .weekly, title: "Weekly", systemImage: "calendar",
                             usedPercentage: 50, resetsAt: future, hasData: true, now: now)
        XCTAssertEqual(card.resetCaption, "2d 1h")
    }

    // MARK: - daily bars

    func testDailyBarsLabelTodayYesterdayAndWeekday() {
        let c = cal()
        let today = c.startOfDay(for: now)
        let days = (0..<7).reversed().map { offset -> DayUsage in
            let day = c.date(byAdding: .day, value: -offset, to: today)!
            return DayUsage(day: day, inputTokens: offset * 100)   // older days heavier
        }
        let bars = dailyUsageBars(days, now: now)
        XCTAssertEqual(bars.count, 7)
        XCTAssertEqual(bars.last?.label, "Today")
        XCTAssertEqual(bars[5].label, "Yest.")
        XCTAssertEqual(bars.first?.label.count, 3)            // a weekday abbreviation
        // intensity is relative to the busiest day (the oldest here, 600 tokens).
        XCTAssertEqual(bars.first?.intensity ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(bars.last?.intensity ?? 1, 0.0, accuracy: 1e-9)
    }

    func testMergeDailyUsageSumsElementwise() {
        let c = cal()
        let base = c.startOfDay(for: now)
        let a = [DayUsage(day: base, inputTokens: 10, outputTokens: 1),
                 DayUsage(day: base, inputTokens: 20)]
        let b = [DayUsage(day: base, inputTokens: 5, outputTokens: 2)]
        let merged = mergeDailyUsage([a, b])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].inputTokens, 15)
        XCTAssertEqual(merged[0].outputTokens, 3)
        XCTAssertEqual(merged[1].inputTokens, 20)   // b has no second day -> a only
    }

    // MARK: - current (non-stale) limit window

    func testCurrentWindowPrefersLatestFreshAndIgnoresStale() {
        let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600))
        let past = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3_600))
        let snaps = [
            // Stale: its window already reset, even though the % is highest.
            snap(captured: now.addingTimeInterval(-30), five: CapturedWindow(usedPercentage: 88, resetsAt: past)),
            snap(captured: now.addingTimeInterval(-20), five: CapturedWindow(usedPercentage: 20, resetsAt: future)),
            snap(captured: now, five: CapturedWindow(usedPercentage: 23, resetsAt: future)),
        ]
        XCTAssertEqual(currentWindow(snaps, { $0.fiveHour }, now: now)?.usedPercentage, 23,
                       "latest FRESH wins, not the stale 88")
    }

    func testCurrentWindowFallsBackToLatestWhenAllStale() {
        let past = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3_600))
        let snaps = [
            snap(captured: now.addingTimeInterval(-30), five: CapturedWindow(usedPercentage: 50, resetsAt: past)),
            snap(captured: now, five: CapturedWindow(usedPercentage: 40, resetsAt: past)),
        ]
        XCTAssertEqual(currentWindow(snaps, { $0.fiveHour }, now: now)?.usedPercentage, 40)
    }

    func testCurrentWindowTreatsNilResetAsFresh() {
        let snaps = [snap(captured: now, five: CapturedWindow(usedPercentage: 33, resetsAt: nil))]
        XCTAssertEqual(currentWindow(snaps, { $0.fiveHour }, now: now)?.usedPercentage, 33)
    }

    // MARK: - model shares

    func testModelSharesSumAcrossSessionsSortedDescending() {
        let sessions: [String: SessionUsage] = [
            "s1": SessionUsage(sessionId: "s1", cwd: "/x", modelBreakdown: ["opus": 75, "haiku": 25]),
            "s2": SessionUsage(sessionId: "s2", cwd: "/y", modelBreakdown: ["opus": 25]),
        ]
        let shares = modelShares(sessions)
        XCTAssertEqual(shares.map(\.model), ["opus", "haiku"])   // opus 100/125, haiku 25/125
        XCTAssertEqual(shares[0].percent, 80, accuracy: 1e-9)
        XCTAssertEqual(shares[1].percent, 20, accuracy: 1e-9)
    }

    // MARK: - token rows

    func testTokenRowsSumCacheTiers() {
        let today = UsageTotals(inputTokens: 100, outputTokens: 200,
                                cacheReadTokens: 10, cacheWrite5mTokens: 5, cacheWrite1hTokens: 5,
                                cost: 1.5)
        let rows = tokenRows(today: today, thisMonth: UsageTotals())
        XCTAssertEqual(rows.map(\.period), ["Today", "Month"])
        XCTAssertEqual(rows[0].input, 100)
        XCTAssertEqual(rows[0].cache, 20)        // 10 read + 5 + 5 write
        XCTAssertEqual(rows[0].cost, 1.5)
    }

    // MARK: - account & overall columns

    func testAccountDashboardUsesLatestCapture() {
        let older = snap(captured: now.addingTimeInterval(-7_200),
                         five: CapturedWindow(usedPercentage: 10, resetsAt: nil))
        let newer = snap(captured: now,
                         five: CapturedWindow(usedPercentage: 80, resetsAt: nil),
                         seven: CapturedWindow(usedPercentage: 96, resetsAt: nil))
        let column = accountDashboard(name: "work", analytics: nil,
                                      snapshots: [older, newer], now: now)
        XCTAssertEqual(column.title, "work")
        XCTAssertEqual(column.fiveHour.usedPercentage, 80)   // latest, not older
        XCTAssertEqual(column.weekly.usedPercentage, 96)
        XCTAssertEqual(column.weekly.level, .critical)
    }

    func testOverallDashboardUsesAggregateUsedPercentage() {
        // One account, tier weight present, 25% used -> aggregate fraction 0.75 -> used 25%.
        let aggregate = RateLimitModel.aggregateRemaining(
            [RateLimitModel.AccountWindow(tier: "default_claude_max_5x", usedPercentage: 25)])
        let analytics = AccountUsageAnalytics(
            accountName: "a", today: UsageTotals(inputTokens: 100, cost: 2),
            thisMonth: UsageTotals(inputTokens: 300, cost: 6), last7d: UsageTotals(),
            sessions: ["s": SessionUsage(sessionId: "s", cwd: "/x", modelBreakdown: ["opus": 10])],
            costByModel: [:], byCwd: [:], unpricedModels: [], unpricedCost: 0)
        let column = overallDashboard(
            analyticsByAccount: ["a": analytics],
            snapshotsByAccount: ["a": [snap(captured: now, five: CapturedWindow(usedPercentage: 25, resetsAt: nil))]],
            aggregateFiveHour: aggregate, aggregateWeekly: aggregate, aggregateSonnet: aggregate, now: now)
        XCTAssertEqual(column.title, "Overall")
        XCTAssertEqual(column.fiveHour.usedPercentage, 25, accuracy: 1e-9)
        XCTAssertTrue(column.fiveHour.hasData)
        XCTAssertTrue(column.weeklySonnet.hasData)
        XCTAssertEqual(column.tokens[0].input, 100)    // today summed
        XCTAssertEqual(column.costToday, 2, accuracy: 1e-9)
        XCTAssertEqual(column.models.first?.model, "opus")
    }

    func testOverallDashboardNoDataIsNeutral() {
        let empty = RateLimitModel.Aggregate(remaining: 0, total: 0)
        let column = overallDashboard(analyticsByAccount: [:], snapshotsByAccount: [:],
                                      aggregateFiveHour: empty, aggregateWeekly: empty,
                                      aggregateSonnet: empty, now: now)
        XCTAssertEqual(column.fiveHour.level, .noData)
        XCTAssertFalse(column.weekly.hasData)
        XCTAssertFalse(column.weeklySonnet.hasData)
    }

    func testFiveHourSessionTrendAveragesCompletedSessionsOnly() {
        let iso = ISO8601DateFormatter()
        let recentPast = iso.string(from: now.addingTimeInterval(-3 * 3_600))
        let olderPast = iso.string(from: now.addingTimeInterval(-9 * 3_600))
        let future = iso.string(from: now.addingTimeInterval(3_600))
        let snaps = [
            // two captures in the SAME completed window → peak (50) wins
            snap(captured: now.addingTimeInterval(-3 * 3_600), five: CapturedWindow(usedPercentage: 30, resetsAt: recentPast)),
            snap(captured: now.addingTimeInterval(-3 * 3_600), five: CapturedWindow(usedPercentage: 50, resetsAt: recentPast)),
            snap(captured: now.addingTimeInterval(-9 * 3_600), five: CapturedWindow(usedPercentage: 40, resetsAt: olderPast)),
            // current window (reset in the future) is EXCLUDED from the trend
            snap(captured: now, five: CapturedWindow(usedPercentage: 99, resetsAt: future)),
        ]
        let trend = fiveHourSessionTrend(snaps, now: now)
        XCTAssertEqual(trend.average ?? 0, 45, accuracy: 1e-9)   // (50 + 40) / 2
        XCTAssertEqual(trend.previous, 50)                        // latest completed window's peak
    }

    func testFiveHourSessionTrendEmptyWhenNoCompletedWindows() {
        let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600))
        let trend = fiveHourSessionTrend(
            [snap(captured: now, five: CapturedWindow(usedPercentage: 20, resetsAt: future))], now: now)
        XCTAssertNil(trend.average)
        XCTAssertNil(trend.previous)
    }

    func testSoonestResetPicksNearestFuture() {
        let soon = ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600))
        let later = ISO8601DateFormatter().string(from: now.addingTimeInterval(10_000))
        let past = ISO8601DateFormatter().string(from: now.addingTimeInterval(-100))
        let result = soonestReset([
            CapturedWindow(usedPercentage: 1, resetsAt: later),
            CapturedWindow(usedPercentage: 1, resetsAt: soon),
            CapturedWindow(usedPercentage: 1, resetsAt: past),
        ], now: now)
        XCTAssertEqual(result, soon)
    }
}
