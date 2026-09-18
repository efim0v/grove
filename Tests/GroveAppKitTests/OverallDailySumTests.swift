import XCTest
import GroveCore
@testable import GroveAppKit

/// "Daily Usage" under Overall must be the sum of every account's day, and the
/// footer must state when the numbers were obtained.
final class OverallDailySumTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func day(_ offsetDays: Int) -> Date {
        UsageCostLedger.utcCalendar.startOfDay(for: now.addingTimeInterval(Double(offsetDays) * 86_400))
    }

    private func usage(_ day: Date, input: Int, cost: Double) -> DayUsage {
        DayUsage(day: day, inputTokens: input, outputTokens: 0, cacheTokens: 0, cost: cost)
    }

    // MARK: - mergeDailyUsage

    func testMergeAddsBucketsThatShareADay() {
        let merged = mergeDailyUsage([
            [usage(day(-1), input: 10, cost: 1), usage(day(0), input: 20, cost: 2)],
            [usage(day(-1), input: 5, cost: 0.5), usage(day(0), input: 7, cost: 0.25)],
        ])
        XCTAssertEqual(merged.map(\.inputTokens), [15, 27])
        XCTAssertEqual(merged.map(\.cost), [1.5, 2.25])
    }

    /// The defect a positional sum hides: a shorter account whose days do not line
    /// up positionally must still land on the RIGHT day, not be added to whatever
    /// index it happens to occupy.
    func testMergeMatchesByDayNotByPosition() {
        let merged = mergeDailyUsage([
            [usage(day(-2), input: 100, cost: 0),
             usage(day(-1), input: 200, cost: 0),
             usage(day(0), input: 400, cost: 0)],
            [usage(day(0), input: 1, cost: 0)],          // only today
        ])
        XCTAssertEqual(merged.map(\.inputTokens), [100, 200, 401],
                       "today's 1 belongs to today, not to the first slot")
    }

    func testMergeOfNothingIsEmpty() {
        XCTAssertTrue(mergeDailyUsage([]).isEmpty)
        XCTAssertTrue(mergeDailyUsage([[]]).isEmpty)
    }

    // MARK: - end to end through overallDashboard

    func testOverallDailyEqualsTheSumOfTheAccountColumns() {
        func analytics(_ name: String, _ days: [DayUsage]) -> AccountUsageAnalytics {
            AccountUsageAnalytics(accountName: name, today: UsageTotals(), thisMonth: UsageTotals(),
                                  last7d: UsageTotals(), daily: days, sessions: [:],
                                  costByModel: [:], byCwd: [:], unpricedModels: [], unpricedCost: 0)
        }
        let a = [usage(day(-1), input: 10, cost: 3), usage(day(0), input: 20, cost: 4)]
        let b = [usage(day(-1), input: 1, cost: 0.5), usage(day(0), input: 2, cost: 1)]
        let overall = overallDashboard(
            analyticsByAccount: ["a": analytics("a", a), "b": analytics("b", b)],
            snapshotsByAccount: [:], limitInputs: [], now: now)
        let columnA = accountDashboard(name: "a", analytics: analytics("a", a), snapshots: [], now: now)
        let columnB = accountDashboard(name: "b", analytics: analytics("b", b), snapshots: [], now: now)
        XCTAssertEqual(overall.daily.map(\.cost),
                       zip(columnA.daily, columnB.daily).map { $0.cost + $1.cost })
        XCTAssertEqual(overall.daily.map(\.totalTokens),
                       zip(columnA.daily, columnB.daily).map { $0.totalTokens + $1.totalTokens })
    }

    /// The ledger override is per-account, so the sum must be taken AFTER each
    /// account's tracked cost replaces its transcript cost.
    func testOverallDailySumsLedgerCorrectedCost() {
        func analytics(_ name: String) -> AccountUsageAnalytics {
            AccountUsageAnalytics(accountName: name, today: UsageTotals(), thisMonth: UsageTotals(),
                                  last7d: UsageTotals(),
                                  daily: [usage(day(0), input: 0, cost: 99)], sessions: [:],
                                  costByModel: [:], byCwd: [:], unpricedModels: [], unpricedCost: 0)
        }
        let overall = overallDashboard(
            analyticsByAccount: ["a": analytics("a"), "b": analytics("b")],
            snapshotsByAccount: [:], limitInputs: [], now: now,
            ledgerCostByAccount: ["a": [day(0): 2], "b": [day(0): 3]])
        XCTAssertEqual(overall.daily.last?.cost, 5, "2 + 3 tracked, not 99 + 99 transcript")
    }
}
