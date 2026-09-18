import XCTest
@testable import GroveCore

final class UsageLedgerStoreTests: XCTestCase {
    private let cal = UsageCostLedger.utcCalendar
    private let now = Date(timeIntervalSince1970: 1_750_000_000)   // 2025-06-15T...Z

    /// A statusline snapshot carrying only the fields the ledger reads.
    private func snap(_ session: String, cost: Double?, at: Date?) -> UsageSnapshot {
        UsageSnapshot(accountName: "a", sessionId: session, capturedAt: at, cwd: nil,
                      modelId: nil, modelDisplayName: nil, effort: nil,
                      contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: cost,
                      fiveHour: nil, sevenDay: nil)
    }
    private func day(_ offset: Int) -> Date {
        cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: now)!)
    }

    // MARK: - fold: seeding, deltas, attribution, monotonicity

    func testFirstObservationSeedsBaselineWithNoDelta() {
        var ledger = UsageCostLedger()
        let changed = UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 100, at: now)], now: now)
        XCTAssertTrue(changed, "seeding a new cursor is a change")
        XCTAssertTrue(ledger.days.isEmpty, "first observation contributes NO per-day cost (no backfill)")
        XCTAssertEqual(ledger.cursors["s"]?.lastCumulativeCostUSD, 100, "baseline recorded")
    }

    func testSecondObservationAccruesDeltaToCapturedDay() {
        var ledger = UsageCostLedger()
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 100, at: now)], now: now)
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 130, at: now)], now: now)
        XCTAssertEqual(ledger.cost(on: day(0)), 30, accuracy: 1e-9, "delta 130-100 lands on today")
        XCTAssertEqual(ledger.cursors["s"]?.lastCumulativeCostUSD, 130)
    }

    func testDeltasAttributeToTheirOwnDay() {
        var ledger = UsageCostLedger()
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 100, at: day(-1))], now: now)  // seed on day-1
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 130, at: day(-1))], now: now)  // +30 day-1
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 150, at: day(0))], now: now)   // +20 today
        XCTAssertEqual(ledger.cost(on: day(-1)), 30, accuracy: 1e-9)
        XCTAssertEqual(ledger.cost(on: day(0)), 20, accuracy: 1e-9)
    }

    func testDecreaseIsIgnoredAndDoesNotLowerTheHighWaterMark() {
        var ledger = UsageCostLedger()
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 100, at: now)], now: now)  // seed
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 130, at: now)], now: now)  // +30
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 120, at: now)], now: now)  // dip: ignored
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 140, at: now)], now: now)  // +10 from 130 HWM
        XCTAssertEqual(ledger.cost(on: day(0)), 40, accuracy: 1e-9, "30 + 10, the dip never subtracts")
        XCTAssertEqual(ledger.cursors["s"]?.lastCumulativeCostUSD, 140)
    }

    func testTwoSnapshotsForOneSessionFoldInCapturedOrder() {
        var ledger = UsageCostLedger()
        // Same session, two captures in one batch, out of order — must end on the latest.
        let batch = [snap("s", cost: 150, at: now), snap("s", cost: 100, at: day(-1))]
        UsageCostLedger.fold(into: &ledger, snapshots: batch, now: now)
        // Ordered by capturedAt: 100@day-1 seeds (delta 0), then 150@today → +50 today.
        XCTAssertEqual(ledger.cost(on: day(0)), 50, accuracy: 1e-9)
        XCTAssertEqual(ledger.cursors["s"]?.lastCumulativeCostUSD, 150)
    }

    func testOAuthAndNilCostSnapshotsAreExcluded() {
        var ledger = UsageCostLedger()
        let changed = UsageCostLedger.fold(into: &ledger, snapshots: [
            snap("oauth", cost: 999, at: now),   // synthetic limit snapshot
            snap("s", cost: nil, at: now),        // no cumulative cost
        ], now: now)
        XCTAssertFalse(changed, "neither contributes a cursor or a delta")
        XCTAssertTrue(ledger.cursors.isEmpty)
        XCTAssertTrue(ledger.days.isEmpty)
    }

    func testNoChangeReturnsFalseSoTheCallerSkipsPersistence() {
        var ledger = UsageCostLedger()
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 100, at: now)], now: now)
        // Re-folding the SAME observation advances nothing.
        let changed = UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 100, at: now)], now: now)
        XCTAssertFalse(changed)
    }

    func testMissingCapturedAtDropsTheDayButStillAdvancesCursor() {
        var ledger = UsageCostLedger()
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 100, at: now)], now: now)
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 130, at: nil)], now: now)  // no day
        XCTAssertTrue(ledger.days.isEmpty, "no captured day → the delta can't be placed, dropped")
        XCTAssertEqual(ledger.cursors["s"]?.lastCumulativeCostUSD, 130,
                       "cursor still advances so the cost is never re-counted later")
    }

    func testStalecursorsArePrunedPastRetention() {
        var ledger = UsageCostLedger()
        // A session last seen 100 days ago, retention 60 days, now → cursor pruned.
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("old", cost: 100, at: day(-100))],
                             now: now, retention: 60 * 86_400)
        XCTAssertNil(ledger.cursors["old"], "cursor older than retention is dropped")
    }

    func testLiveButCostFlatSessionSurvivesPruningAndKeepsAccruing() {
        let t0 = now
        var ledger = UsageCostLedger()
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 100, at: t0)], now: t0)  // seed
        // 90 days later, a FLAT observation (cost still 100) with a fresh capturedAt — the
        // statusline re-renders the file even without new cost. lastObservedAt must advance, so
        // this live session is NOT pruned (the bug: it pruned, then mis-re-seeded, dropping cost).
        let later = t0.addingTimeInterval(90 * 86_400)
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 100, at: later)],
                             now: later, retention: 60 * 86_400)
        XCTAssertNotNil(ledger.cursors["s"], "flat-cost but recently-observed session survives pruning")
        // A later increase then attributes a real delta instead of being lost to a re-seed.
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 130, at: later)], now: later)
        XCTAssertEqual(ledger.cost(on: UsageCostLedger.utcCalendar.startOfDay(for: later)), 30,
                       accuracy: 1e-9, "the increment lands on its day, not lost to a mis-re-seed")
    }

    // MARK: - store round-trip

    func testStoreSaveLoadRoundTrip() throws {
        let dir = try Fixture.tempDir("usage-ledger").appendingPathComponent("usageledger")
        let store = UsageCostLedgerStore(dir: dir)
        XCTAssertEqual(store.load(account: "default"), UsageCostLedger(), "missing file → empty")
        var ledger = UsageCostLedger()
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 100, at: now)], now: now)
        UsageCostLedger.fold(into: &ledger, snapshots: [snap("s", cost: 130, at: now)], now: now)
        try store.save(account: "apple/work", ledger: ledger)   // path-hostile name still safe
        XCTAssertEqual(store.load(account: "apple/work"), ledger, "round-trips exactly")
        store.delete(account: "apple/work")
        XCTAssertEqual(store.load(account: "apple/work"), UsageCostLedger(), "deleted → empty")
    }
}
