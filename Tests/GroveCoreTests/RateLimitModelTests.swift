import XCTest
@testable import GroveCore

final class RateLimitModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - tier -> relative capacity weight (single maintainable table)

    func testTierWeightsCoverKnownTiersAndFlagUnknown() {
        XCTAssertEqual(RateLimitModel.weight(forTier: "default_claude_max_20x").value, 20)
        XCTAssertEqual(RateLimitModel.weight(forTier: "default_claude_max_5x").value, 5)
        XCTAssertEqual(RateLimitModel.weight(forTier: "default_claude_pro").value, 1)
        // Unknown tier -> weight 1 AND flagged so the UI can surface it.
        let unknown = RateLimitModel.weight(forTier: "future_tier_xyz")
        XCTAssertEqual(unknown.value, 1)
        XCTAssertTrue(unknown.isUnknown)
        // nil tier (not logged in / no oauthAccount) -> 1, flagged.
        XCTAssertTrue(RateLimitModel.weight(forTier: nil).isUnknown)
    }

    // MARK: - per-window status from used% + resets_at + injected now

    func testWindowStatusComputesRemainingAndResetCountdown() throws {
        // resets_at one hour after `now`.
        let resets = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        let w = RateLimitModel.window(usedPercentage: 30, resetsAt: resets, now: now)
        XCTAssertEqual(w.usedPercentage, 30, accuracy: 1e-9)
        XCTAssertEqual(w.remainingFraction, 0.7, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(w.resetsIn), 3600, accuracy: 1.0)        // ~1h
        XCTAssertFalse(w.isExpired)
    }

    func testWindowStatusHandlesAbsentResetsAtAndPastReset() {
        let none = RateLimitModel.window(usedPercentage: 10, resetsAt: nil, now: now)
        XCTAssertNil(none.resetsIn)                            // no countdown without resets_at
        let past = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let expired = RateLimitModel.window(usedPercentage: 90, resetsAt: past, now: now)
        XCTAssertTrue(expired.isExpired)                      // reset already passed
    }

    // MARK: - aggregate remaining = Σ weight·(1 − used%) per window

    func testAggregateRemainingWeightsAccountsByTier() {
        // Two accounts: max_20x at 50% used, max_5x at 0% used, same window.
        let a = RateLimitModel.AccountWindow(tier: "default_claude_max_20x", usedPercentage: 50)
        let b = RateLimitModel.AccountWindow(tier: "default_claude_max_5x", usedPercentage: 0)
        let agg = RateLimitModel.aggregateRemaining([a, b])
        // 20*(1-0.5) + 5*(1-0) = 10 + 5 = 15 of a total weight 25.
        XCTAssertEqual(agg.remaining, 15, accuracy: 1e-9)
        XCTAssertEqual(agg.total, 25, accuracy: 1e-9)
        XCTAssertEqual(agg.fraction, 15.0 / 25.0, accuracy: 1e-9)
    }

    func testAggregateRemainingEmptyIsZeroNotNaN() {
        let agg = RateLimitModel.aggregateRemaining([])
        XCTAssertEqual(agg.remaining, 0)
        XCTAssertEqual(agg.total, 0)
        XCTAssertEqual(agg.fraction, 0, "empty must not divide-by-zero into NaN")
    }
}
