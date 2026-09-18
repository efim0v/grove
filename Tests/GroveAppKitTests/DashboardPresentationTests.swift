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
            return DayUsage(day: day, inputTokens: offset * 100,
                            cost: Double(offset))            // older days heavier (by COST now)
        }
        let bars = dailyUsageBars(days, now: now)
        XCTAssertEqual(bars.count, 7)
        XCTAssertEqual(bars.last?.label, "Today")
        XCTAssertEqual(bars[5].label, "Yest.")
        XCTAssertEqual(bars.first?.label.count, 3)            // a weekday abbreviation
        // intensity is now relative to the busiest day BY COST (the oldest here, $6).
        XCTAssertEqual(bars.first?.intensity ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(bars.last?.intensity ?? 1, 0.0, accuracy: 1e-9)
    }

    func testMergeLedgerCostOverridesTrackedDaysAndKeepsUntracked() {
        let c = cal()
        let d0 = c.startOfDay(for: now)
        let d1 = c.date(byAdding: .day, value: -1, to: d0)!
        let daily = [DayUsage(day: d1, inputTokens: 100, cost: 2.0),
                     DayUsage(day: d0, inputTokens: 200, cost: 5.0)]
        // Ledger tracked only d0 (a different cost); d1 is untracked (absent from the dict).
        let merged = mergeLedgerCost(daily, ledgerCostByDay: [d0: 9.5])
        XCTAssertEqual(merged[0].cost, 2.0, accuracy: 1e-9, "untracked day keeps transcript cost")
        XCTAssertEqual(merged[1].cost, 9.5, accuracy: 1e-9, "tracked day uses the ledger delta")
        XCTAssertEqual(merged[0].inputTokens, 100, "tokens carried through unchanged")
        XCTAssertEqual(merged[1].inputTokens, 200)
        // A tracked day with a genuine zero overrides transcript to 0 (membership, not value, gates it).
        let merged0 = mergeLedgerCost(daily, ledgerCostByDay: [d0: 0])
        XCTAssertEqual(merged0[1].cost, 0, accuracy: 1e-9, "tracked-but-zero overrides to 0")
    }

    /// End-to-end through `accountDashboard`: the ledger cost-by-day must override the right
    /// column day. This is also the cross-module DAY-KEY ALIGNMENT guard — the ledger key is a
    /// UTC start-of-day and the analytics daily axis is the same; if either calendar diverged the
    /// override would silently miss and this fails.
    func testAccountDashboardAppliesLedgerCostByDay() {
        let c = cal()
        let tracked = c.startOfDay(for: now)                            // a day on the 7-day axis
        let untracked = c.date(byAdding: .day, value: -3, to: tracked)!
        let analytics = AccountUsageAnalytics(
            accountName: "a", today: UsageTotals(), thisMonth: UsageTotals(), last7d: UsageTotals(),
            daily: [DayUsage(day: untracked, inputTokens: 10, cost: 1.0),
                    DayUsage(day: tracked, inputTokens: 20, cost: 4.0)],
            sessions: [:], costByModel: [:], byCwd: [:], unpricedModels: [], unpricedCost: 0)
        let col = accountDashboard(name: "a", analytics: analytics, snapshots: [], now: now,
                                   ledgerCostByDay: [tracked: 9.5])
        XCTAssertEqual(col.daily.first { $0.day == tracked }?.cost ?? 0, 9.5, accuracy: 1e-9,
                       "ledger delta overrides transcript on the tracked day (day keys aligned)")
        XCTAssertEqual(col.daily.first { $0.day == untracked }?.cost ?? 0, 1.0, accuracy: 1e-9,
                       "untracked day keeps its transcript cost")
    }

    func testMergeDailyUsageSumsAccountsDayByDay() {
        let c = cal()
        let day1 = c.startOfDay(for: now)
        let day2 = c.date(byAdding: .day, value: 1, to: day1)!
        let a = [DayUsage(day: day1, inputTokens: 10, outputTokens: 1),
                 DayUsage(day: day2, inputTokens: 20)]
        let b = [DayUsage(day: day1, inputTokens: 5, outputTokens: 2)]
        let merged = mergeDailyUsage([a, b])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].inputTokens, 15)
        XCTAssertEqual(merged[0].outputTokens, 3)
        XCTAssertEqual(merged[1].inputTokens, 20)   // b has no bucket for day2 -> a only
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

    // MARK: - tokenCellText (em-dash for zero counts)

    func testTokenCellTextZeroIsEmDash() {
        XCTAssertEqual(tokenCellText(count: 0), "—",
                       "zero token count must render em-dash, not '0'")
    }

    func testTokenCellTextNonZeroUsesCompactFormatter() {
        // 1_234 -> "1.2k" (one decimal, lowercase k)
        XCTAssertEqual(tokenCellText(count: 1_234), "1.2k")
        XCTAssertEqual(tokenCellText(count: 999), "999")
        XCTAssertEqual(tokenCellText(count: 3_000_000), "3M")
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

    // MARK: - tokenRows ledger-cost fallback

    func testTokenRowsLedgerFallbackUsedWhenTranscriptCostZero() {
        // transcript cost is 0 (lost days); ledger has real cost — ledger must win
        let rows = tokenRows(today: UsageTotals(cost: 0), thisMonth: UsageTotals(cost: 0),
                             ledgerTodayCost: 923.0, ledgerMonthCost: 1_500.0)
        XCTAssertEqual(rows[0].cost, 923.0, accuracy: 1e-9,
                       "Today row must use ledger cost when transcript is 0")
        XCTAssertEqual(rows[1].cost, 1_500.0, accuracy: 1e-9,
                       "Month row must use ledger cost when transcript is 0")
    }

    func testTokenRowsTranscriptCostPreferredWhenNonZero() {
        // transcript has real cost — must NOT be overridden by the ledger
        let rows = tokenRows(today: UsageTotals(cost: 5.0), thisMonth: UsageTotals(cost: 12.0),
                             ledgerTodayCost: 923.0, ledgerMonthCost: 1_500.0)
        XCTAssertEqual(rows[0].cost, 5.0, accuracy: 1e-9,
                       "Today row must prefer transcript cost when non-zero")
        XCTAssertEqual(rows[1].cost, 12.0, accuracy: 1e-9,
                       "Month row must prefer transcript cost when non-zero")
    }

    func testTokenRowsNilLedgerCostLeavesZeroAsZero() {
        // no ledger at all — cost stays at 0 (not crashing / not substituting garbage)
        let rows = tokenRows(today: UsageTotals(cost: 0), thisMonth: UsageTotals(cost: 0),
                             ledgerTodayCost: nil, ledgerMonthCost: nil)
        XCTAssertEqual(rows[0].cost, 0, accuracy: 1e-9)
        XCTAssertEqual(rows[1].cost, 0, accuracy: 1e-9)
    }

    // MARK: - ledgerMonthCost bucketing

    func testLedgerMonthCostSumsOnlyCurrentMonthDays() {
        // Build a ledger whose days span two months; only the current month's days must sum.
        let c = UsageCostLedger.utcCalendar
        // now = 2025-06-15; current month is June 2025.
        let today = c.startOfDay(for: now)                      // 2025-06-15
        let twoMonthsAgo = c.date(byAdding: .month, value: -2, to: today)!  // ~2025-04-15
        let prevMonth    = c.date(byAdding: .month, value: -1, to: today)!  // ~2025-05-15
        let ledger = UsageCostLedger(days: [
            LedgerDay(day: twoMonthsAgo, costUSD: 100),
            LedgerDay(day: prevMonth,    costUSD: 50),
            LedgerDay(day: today,        costUSD: 30),
        ])
        let monthCost = ledgerMonthCost(ledger: ledger, now: now)
        XCTAssertEqual(monthCost, 30, accuracy: 1e-9,
                       "Only the current UTC calendar month's days should be summed")
    }

    func testLedgerTodayCostReturnsDayTotal() {
        let c = UsageCostLedger.utcCalendar
        let today = c.startOfDay(for: now)
        let yesterday = c.date(byAdding: .day, value: -1, to: today)!
        let ledger = UsageCostLedger(days: [
            LedgerDay(day: yesterday, costUSD: 10),
            LedgerDay(day: today, costUSD: 42),
        ])
        XCTAssertEqual(ledgerTodayCost(ledger: ledger, now: now), 42, accuracy: 1e-9)
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
            limitInputs: [AccountLimitInput(account: "a", tier: "default_claude_max_5x",
                                            fiveHour: CapturedWindow(usedPercentage: 25, resetsAt: nil),
                                            weekly: CapturedWindow(usedPercentage: 25, resetsAt: nil),
                                            weeklySonnet: CapturedWindow(usedPercentage: 25, resetsAt: nil),
                                            scopedModel: nil, scopedWindow: nil)],
            now: now)
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
                                      limitInputs: [], now: now)
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
