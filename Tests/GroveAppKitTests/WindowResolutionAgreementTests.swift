import XCTest
import GroveCore
@testable import GroveAppKit

/// The chip "default 81%" under Overall's Weekly Limit and the Weekly Limit bar on
/// the "default" tab are the SAME quantity and must never disagree. They used to:
/// the account column took the most recently captured value, while Overall preferred
/// the statusline source whenever its window had not yet reset — and "not yet reset"
/// is not the same as "recently captured". The statusline only re-renders when a
/// session redraws, so it routinely lags the OAuth reading fetched on panel open.
@MainActor
final class WindowResolutionAgreementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private var root: URL!

    override func setUp() async throws {
        root = try FixtureLite.tempDir("window-agreement")
    }

    private func state() -> AppState {
        let s = AppState(configStore: ConfigStore(url: root.appendingPathComponent("c.json")))
        s.canonicalDirOverride = root.appendingPathComponent("canonical").path
        s.usageLedgerStoreDirOverride = root.appendingPathComponent("ledger").path
        s.config.accounts = [AccountConfig(name: "default", configDir: "/tmp/does-not-matter")]
        return s
    }

    /// A window that has NOT reset yet, so neither resolver may discard it as stale.
    private func window(_ used: Double) -> CapturedWindow {
        CapturedWindow(usedPercentage: used,
                       resetsAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(6 * 3_600)))
    }

    private func capture(session: String, agoSeconds: TimeInterval, weekly: Double) -> UsageSnapshot {
        UsageSnapshot(accountName: "default", sessionId: session,
                      capturedAt: now.addingTimeInterval(-agoSeconds), cwd: nil,
                      modelId: nil, modelDisplayName: nil, effort: nil,
                      contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                      fiveHour: nil, sevenDay: window(weekly))
    }

    /// The exact reported case: statusline rendered 5 minutes ago at 81%, OAuth
    /// fetched moments ago at 83%.
    private func mixedCaptures() -> [UsageSnapshot] {
        [capture(session: "s1", agoSeconds: 300, weekly: 81),
         capture(session: "oauth", agoSeconds: 2, weekly: 83)]
    }

    func testOverallChipAgreesWithTheAccountColumn() throws {
        let s = state()
        s.snapshotsByAccount = ["default": mixedCaptures()]
        let column = accountDashboard(name: "default", analytics: nil,
                                     snapshots: mixedCaptures(), now: now)
        let input = try XCTUnwrap(s.accountLimitInputs(now: now).first)
        XCTAssertEqual(input.weekly?.usedPercentage, column.weekly.usedPercentage,
                       "Overall's per-account value must equal the account column's")
    }

    func testBothResolveToTheMostRecentlyCapturedReading() throws {
        let s = state()
        s.snapshotsByAccount = ["default": mixedCaptures()]
        let input = try XCTUnwrap(s.accountLimitInputs(now: now).first)
        XCTAssertEqual(input.weekly?.usedPercentage, 83,
                       "the 2-second-old reading wins over the 5-minute-old one")
    }

    /// Direction must not matter: a fresh STATUSLINE render must beat an older OAuth
    /// capture just as readily as the reverse.
    func testANewerStatuslineReadingWinsOverAnOlderOAuthOne() {
        let captures = [capture(session: "oauth", agoSeconds: 600, weekly: 70),
                        capture(session: "s1", agoSeconds: 5, weekly: 90)]
        XCTAssertEqual(currentWindow(captures, { $0.sevenDay }, now: now)?.usedPercentage, 90)
    }

    /// An account whose statusline carries no window at all still contributes via
    /// OAuth — the inclusion guarantee the source split was originally added for.
    func testOAuthOnlyAccountStillResolves() {
        let statuslineWithoutWindow = UsageSnapshot(
            accountName: "default", sessionId: "s1", capturedAt: now, cwd: nil,
            modelId: nil, modelDisplayName: nil, effort: nil, contextUsedPercentage: nil,
            totalInputTokens: nil, totalCostUSD: nil, fiveHour: nil, sevenDay: nil)
        let captures = [statuslineWithoutWindow,
                        capture(session: "oauth", agoSeconds: 60, weekly: 44)]
        XCTAssertEqual(currentWindow(captures, { $0.sevenDay }, now: now)?.usedPercentage, 44)
    }

    /// An already-reset window loses to a still-valid one even when captured later:
    /// after a reset the old percentage is meaningless.
    func testAnAlreadyResetWindowLosesToAValidOne() {
        let reset = CapturedWindow(
            usedPercentage: 99,
            resetsAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)))
        let stale = UsageSnapshot(accountName: "default", sessionId: "s2", capturedAt: now,
                                  cwd: nil, modelId: nil, modelDisplayName: nil, effort: nil,
                                  contextUsedPercentage: nil, totalInputTokens: nil,
                                  totalCostUSD: nil, fiveHour: nil, sevenDay: reset)
        let captures = [stale, capture(session: "s1", agoSeconds: 300, weekly: 12)]
        XCTAssertEqual(currentWindow(captures, { $0.sevenDay }, now: now)?.usedPercentage, 12)
    }
}
