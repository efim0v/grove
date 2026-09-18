import XCTest
import GroveCore
@testable import GroveAppKit

/// "Overall" has to answer *which account* has headroom left, and it has to stop
/// pretending every account runs the same model. The aggregate percentage itself
/// stays tier-weighted; the chips carry the raw per-account numbers.
final class OverallDetailTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func window(_ used: Double, resetsIn: TimeInterval? = nil) -> CapturedWindow {
        let resets = resetsIn.map { ISO8601DateFormatter().string(from: now.addingTimeInterval($0)) }
        return CapturedWindow(usedPercentage: used, resetsAt: resets)
    }

    private func input(_ account: String, tier: String? = "default_claude_max_5x",
                       five: CapturedWindow? = nil, weekly: CapturedWindow? = nil,
                       sonnet: CapturedWindow? = nil,
                       scopedModel: String? = nil, scoped: CapturedWindow? = nil) -> AccountLimitInput {
        AccountLimitInput(account: account, tier: tier, fiveHour: five, weekly: weekly,
                          weeklySonnet: sonnet, scopedModel: scopedModel, scopedWindow: scoped)
    }

    private func overall(_ inputs: [AccountLimitInput]) -> DashboardColumn {
        overallDashboard(analyticsByAccount: [:], snapshotsByAccount: [:],
                         limitInputs: inputs, now: now)
    }

    // MARK: - per-account chips

    func testFiveHourChipsCarryEveryAccountWithData() {
        let column = overall([
            input("work", five: window(12)),
            input("personal", five: window(56)),
        ])
        XCTAssertEqual(column.fiveHour.perAccount.map(\.account), ["personal", "work"])
        XCTAssertEqual(column.fiveHour.perAccount.map(\.usedPercentage), [56, 12])
    }

    /// Sorted by load descending — the account closest to its limit reads first.
    func testChipsSortByLoadDescendingThenName() {
        let column = overall([
            input("bravo", weekly: window(40)),
            input("alpha", weekly: window(40)),
            input("charlie", weekly: window(90)),
        ])
        XCTAssertEqual(column.weekly.perAccount.map(\.account), ["charlie", "alpha", "bravo"])
    }

    func testAccountsWithoutThatWindowAreOmittedFromItsChips() {
        let column = overall([
            input("work", five: window(12), weekly: window(30)),
            input("apple", five: nil, weekly: window(70)),
        ])
        XCTAssertEqual(column.fiveHour.perAccount.map(\.account), ["work"])
        XCTAssertEqual(column.weekly.perAccount.map(\.account), ["apple", "work"])
    }

    func testChipCarriesItsOwnCapacityLevel() {
        let column = overall([input("work", five: window(95)), input("calm", five: window(5))])
        XCTAssertEqual(column.fiveHour.perAccount.first?.level, .critical)
        XCTAssertEqual(column.fiveHour.perAccount.last?.level, .plenty)
    }

    /// A single account's own column is unchanged — chips belong to Overall only.
    func testAccountColumnHasNoChips() {
        let snapshot = UsageSnapshot(accountName: "work", sessionId: "s", capturedAt: now,
                                     cwd: nil, modelId: nil, modelDisplayName: nil, effort: nil,
                                     contextUsedPercentage: nil, totalInputTokens: nil,
                                     totalCostUSD: nil, fiveHour: window(30), sevenDay: nil)
        let column = accountDashboard(name: "work", analytics: nil,
                                      snapshots: [snapshot], now: now)
        XCTAssertTrue(column.fiveHour.perAccount.isEmpty)
    }

    // MARK: - tier weighting is preserved

    func testAggregateStaysTierWeighted() {
        // Pro (weight 1) at 0% used and Max 20x (weight 20) at 100% used.
        // Weighted: remaining = 1*1 + 20*0 = 1 of total 21 -> ~95.2% used.
        // A plain mean would say 50%.
        let column = overall([
            input("pro", tier: "default_claude_pro", weekly: window(0)),
            input("max", tier: "default_claude_max_20x", weekly: window(100)),
        ])
        XCTAssertEqual(column.weekly.usedPercentage, 100.0 * 20.0 / 21.0, accuracy: 1e-9)
    }

    func testNoInputsMeansNoData() {
        let column = overall([])
        XCTAssertEqual(column.fiveHour.level, .noData)
        XCTAssertFalse(column.weekly.hasData)
        XCTAssertTrue(column.weeklyModels.isEmpty)
    }

    // MARK: - one bar per model

    func testAccountsOnDifferentModelsGetSeparateBars() {
        let column = overall([
            input("work", scopedModel: "Fable", scoped: window(20)),
            input("personal", scopedModel: "Fable", scoped: window(60)),
            input("apple", scopedModel: "Opus", scoped: window(80)),
        ])
        XCTAssertEqual(column.weeklyModels.map(\.title), ["Weekly Fable", "Weekly Opus"])
        XCTAssertEqual(column.weeklyModels[0].perAccount.map(\.account), ["personal", "work"])
        XCTAssertEqual(column.weeklyModels[1].perAccount.map(\.account), ["apple"])
    }

    /// Each model's percentage averages only ITS OWN accounts — an Opus account must
    /// not move the Fable bar.
    func testEachModelBarAggregatesOnlyItsOwnAccounts() throws {
        let column = overall([
            input("work", tier: "default_claude_pro", scopedModel: "Fable", scoped: window(40)),
            input("apple", tier: "default_claude_pro", scopedModel: "Opus", scoped: window(90)),
        ])
        XCTAssertEqual(column.weeklyModels.count, 2)
        let fable = try XCTUnwrap(column.weeklyModels.first { $0.title == "Weekly Fable" })
        let opus = try XCTUnwrap(column.weeklyModels.first { $0.title == "Weekly Opus" })
        XCTAssertEqual(fable.usedPercentage, 40, accuracy: 1e-9)
        XCTAssertEqual(opus.usedPercentage, 90, accuracy: 1e-9)
    }

    func testAllAccountsOnOneModelCollapseToASingleBar() {
        let column = overall([
            input("work", scopedModel: "Fable", scoped: window(20)),
            input("personal", scopedModel: "Fable", scoped: window(60)),
        ])
        XCTAssertEqual(column.weeklyModels.count, 1)
        XCTAssertEqual(column.weeklyModels[0].title, "Weekly Fable")
    }

    /// Bigger groups first, so the model most accounts are on leads.
    func testModelBarsSortByAccountCountThenTitle() {
        let column = overall([
            input("a", scopedModel: "Opus", scoped: window(10)),
            input("b", scopedModel: "Fable", scoped: window(10)),
            input("c", scopedModel: "Fable", scoped: window(10)),
        ])
        XCTAssertEqual(column.weeklyModels.map(\.title), ["Weekly Fable", "Weekly Opus"])
    }

    func testModelBarShowsTheSoonestResetInItsGroup() {
        let column = overall([
            input("late", scopedModel: "Fable", scoped: window(10, resetsIn: 86_400)),
            input("soon", scopedModel: "Fable", scoped: window(10, resetsIn: 3_600)),
        ])
        XCTAssertEqual(column.weeklyModels[0].resetCaption, "1h 0m")
    }

    func testAccountWithoutAScopedModelContributesNoBar() {
        let column = overall([input("work", five: window(10))])
        XCTAssertTrue(column.weeklyModels.isEmpty)
    }
}
