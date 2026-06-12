import XCTest
import GroveCore
@testable import GroveAppKit

final class UsagePresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    func testLimitBarColorGradesByRemaining() {
        // Plenty -> green; tight -> orange; exhausted -> red (thresholds documented in source).
        XCTAssertEqual(LimitBar(usedPercentage: 10, resetsAt: nil, now: now).level, .plenty)
        XCTAssertEqual(LimitBar(usedPercentage: 80, resetsAt: nil, now: now).level, .tight)
        XCTAssertEqual(LimitBar(usedPercentage: 97, resetsAt: nil, now: now).level, .critical)
    }

    func testLimitBarFormatsResetCountdown() {
        let resets = ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 3600 + 30 * 60))
        let bar = LimitBar(usedPercentage: 50, resetsAt: resets, now: now)
        XCTAssertEqual(bar.resetCaption, "resets in 3h 30m")
        XCTAssertEqual(LimitBar(usedPercentage: 50, resetsAt: nil, now: now).resetCaption, "")
    }

    func testModelBreakdownPercentagesSumTo100ForKnownTokens() throws {
        let breakdown = modelBreakdownPercentages(["a": 750, "b": 250])
        XCTAssertEqual(try XCTUnwrap(breakdown["a"]), 75, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(breakdown["b"]), 25, accuracy: 0.01)
        XCTAssertTrue(modelBreakdownPercentages([:]).isEmpty, "no tokens -> empty, no NaN")
    }

    func testAggregateBadgeColorGrades() {
        XCTAssertEqual(AggregateBadge(fraction: 0.8).level, .plenty)
        XCTAssertEqual(AggregateBadge(fraction: 0.3).level, .tight)
        XCTAssertEqual(AggregateBadge(fraction: 0.05).level, .critical)
    }

    /// FIX I4: zero usage captures -> NEUTRAL .noData, NOT .critical, so the badge
    /// renders gray (not red) on every snapshot scene that has no captures.
    func testAggregateBadgeIsNeutralWhenNoData() {
        // An empty aggregate has total == 0 (no captures) -> .noData.
        let empty = RateLimitModel.aggregateRemaining([])   // remaining 0, total 0
        XCTAssertEqual(AggregateBadge(empty).level, .noData)
        XCTAssertFalse(AggregateBadge(empty).hasData)
        // A real aggregate with capacity grades normally (not .noData).
        let real = RateLimitModel.Aggregate(remaining: 8, total: 10)   // fraction 0.8 -> .plenty
        XCTAssertEqual(AggregateBadge(real).level, .plenty)
        XCTAssertTrue(AggregateBadge(real).hasData)
        // hasData:false with a nonzero fraction still grades .noData (zero captures wins).
        XCTAssertEqual(AggregateBadge(fraction: 0.9, hasData: false).level, .noData)
    }
}
