import XCTest
import GroveCore
@testable import GroveAppKit

/// The panel's footer states when the limits were last really obtained, and its
/// refresh button forces a fetch. Both need `refreshUsage` to publish honest state.
@MainActor
final class AppStateUsageFreshnessTests: XCTestCase {
    private var configURL: URL!
    private var root: URL!

    override func setUp() async throws {
        root = try FixtureLite.tempDir("appstate-freshness")
        configURL = root.appendingPathComponent("config.json")
    }

    private func state() -> AppState {
        let s = AppState(configStore: ConfigStore(url: configURL))
        s.canonicalDirOverride = root.appendingPathComponent("canonical").path
        s.usageLedgerStoreDirOverride = root.appendingPathComponent("ledger").path
        return s
    }

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    /// A synthetic OAuth capture must be dated by the fetch, not by the refresh tick —
    /// otherwise three-minute-old cached numbers would read as current.
    func testOAuthSnapshotIsDatedByTheFetchNotTheTick() throws {
        let fetched = now.addingTimeInterval(-180)
        let snap = AppState.oauthSnapshot(
            accountName: "a",
            usage: OAuthUsage(fiveHour: OAuthWindow(utilization: 5, resetsAt: nil),
                              sevenDay: nil, sevenDaySonnet: nil, sevenDayOpus: nil,
                              fetchedAt: fetched),
            now: now)
        XCTAssertEqual(snap?.capturedAt, fetched)
    }

    /// With no fetch time on record the tick is the best available answer.
    func testOAuthSnapshotFallsBackToNowWhenFetchTimeUnknown() throws {
        let snap = AppState.oauthSnapshot(
            accountName: "a",
            usage: OAuthUsage(fiveHour: OAuthWindow(utilization: 5, resetsAt: nil),
                              sevenDay: nil, sevenDaySonnet: nil, sevenDayOpus: nil),
            now: now)
        XCTAssertEqual(snap?.capturedAt, now)
    }

    func testUsageDataAsOfIsTheNewestCaptureAcrossAccounts() async throws {
        let s = state()
        let dir = try FixtureLite.tempDir("asof-acct")
        s.config.accounts = [AccountConfig(name: "apple", configDir: dir.path)]
        s.config.usage.oauthLiveEnabled = true
        let fetched = now.addingTimeInterval(-120)
        s.oauthLimitsOverride = { _, _ in
            OAuthUsage(fiveHour: OAuthWindow(utilization: 22, resetsAt: nil),
                       sevenDay: nil, sevenDaySonnet: nil, sevenDayOpus: nil,
                       fetchedAt: fetched)
        }
        await s.refreshUsage(now: now, oauth: .fetch)
        XCTAssertEqual(s.usageDataAsOf, fetched,
                       "a cached OAuth reading must not be reported as fresh")
    }

    func testUsageDataAsOfIsNilWithoutAnyCaptures() async throws {
        let s = state()
        s.config.accounts = []
        await s.refreshUsage(now: now)
        XCTAssertNil(s.usageDataAsOf)
    }

    /// The refresh button works with the panel closed and the live poll off — the
    /// tap IS the explicit gesture the OAuth gate asks for.
    func testForcedRefreshFetchesOAuthEvenWhenGatedOff() async throws {
        let s = state()
        let dir = try FixtureLite.tempDir("forced-acct")
        s.config.accounts = [AccountConfig(name: "apple", configDir: dir.path)]
        s.isPanelOpen = false
        s.config.usage.oauthLiveEnabled = false
        var oauthCalled = false
        s.oauthLimitsOverride = { _, _ in
            oauthCalled = true
            return OAuthUsage(fiveHour: OAuthWindow(utilization: 22, resetsAt: nil),
                              sevenDay: nil, sevenDaySonnet: nil, sevenDayOpus: nil,
                              fetchedAt: self.now)
        }
        await s.refreshUsage(now: now, oauth: .force)
        XCTAssertTrue(oauthCalled, "an explicit refresh must fetch OAuth")
    }

    func testRefreshClearsTheInFlightFlagWhenDone() async throws {
        let s = state()
        s.config.accounts = []
        XCTAssertFalse(s.isRefreshingUsage)
        await s.refreshUsage(now: now, oauth: .force)
        XCTAssertFalse(s.isRefreshingUsage, "the indicator must not stick after a refresh")
    }
}
