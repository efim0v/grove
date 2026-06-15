import XCTest
import GroveCore
@testable import GroveAppKit

/// FIX I2 — the Overall scope's consolidated limit cards must include EVERY
/// account: an account whose statusline snapshots carry no rate_limits but whose
/// limits come from the OAuth usage API (e.g. "work-account") must still
/// contribute to aggregateRemaining, not be silently dropped.
@MainActor
final class OverallConsolidationTests: XCTestCase {
    private var root: URL!
    private var configURL: URL!

    override func setUp() async throws {
        root = try FixtureLite.tempDir("overall-consolidation")
        configURL = root.appendingPathComponent("config.json")
    }

    private func makeState() -> AppState {
        let state = AppState(configStore: ConfigStore(url: configURL))
        state.canonicalDirOverride = root.appendingPathComponent("canonical-default").path
        return state
    }

    /// A statusline-style capture (rate_limits present on five_hour / seven_day).
    private func statuslineSnap(account: String, five: Double?, seven: Double?,
                               now: Date) -> UsageSnapshot {
        UsageSnapshot(accountName: account, sessionId: "s1", capturedAt: now, cwd: nil,
                      modelId: nil, modelDisplayName: nil, effort: nil,
                      contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                      fiveHour: five.map { CapturedWindow(usedPercentage: $0, resetsAt: nil) },
                      sevenDay: seven.map { CapturedWindow(usedPercentage: $0, resetsAt: nil) })
    }

    /// A statusline capture for an account whose statusline carries NO rate_limits
    /// at all — every window nil, exactly like "work-account".
    private func statuslineNoLimits(account: String, now: Date) -> UsageSnapshot {
        UsageSnapshot(accountName: account, sessionId: "s1", capturedAt: now, cwd: nil,
                      modelId: nil, modelDisplayName: nil, effort: nil,
                      contextUsedPercentage: nil, totalInputTokens: 123, totalCostUSD: 0.5,
                      fiveHour: nil, sevenDay: nil)
    }

    // MARK: - aggregateRemaining across statusline + OAuth-only accounts

    /// "default" has a statusline 5h capture; "work-account" has NO statusline
    /// rate_limits but OAuth supplies its 5h + weekly. Both must contribute to the
    /// Overall (aggregateRemaining) limit cards for EVERY window.
    func testAggregateConsolidatesStatuslineAndOAuthOnlyAccount() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let state = makeState()
        state.config = GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}", projects: [],
            accounts: [AccountConfig(name: "default", configDir: root.appendingPathComponent("default").path),
                       AccountConfig(name: "work-account", configDir: root.appendingPathComponent("apple").path)])
        state.tierOverride = ["default": "default_claude_max_20x",
                              "work-account": "default_claude_max_20x"]

        // "default": statusline 5h=50%, 7d=20%. "work-account": statusline carries
        // NO rate_limits, but OAuth supplies 5h=80%, 7d=10%, sonnet=5%.
        let future = "2025-06-15T18:00:00Z"  // resets_at after `now`, so not stale
        state.snapshotsByAccount = [
            "default": [UsageSnapshot(accountName: "default", sessionId: "s1", capturedAt: now,
                                      cwd: nil, modelId: nil, modelDisplayName: nil, effort: nil,
                                      contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                                      fiveHour: CapturedWindow(usedPercentage: 50, resetsAt: future),
                                      sevenDay: CapturedWindow(usedPercentage: 20, resetsAt: future))],
            "work-account": [statuslineNoLimits(account: "work-account", now: now)],
        ]

        // Fold in work-account's OAuth limits exactly as refreshUsage would.
        let oauth = OAuthUsage(
            fiveHour: OAuthWindow(utilization: 80, resetsAt: future),
            sevenDay: OAuthWindow(utilization: 10, resetsAt: future),
            sevenDaySonnet: OAuthWindow(utilization: 5, resetsAt: future),
            sevenDayOpus: nil)
        if let snap = AppState.oauthSnapshot(accountName: "work-account", usage: oauth, now: now) {
            state.snapshotsByAccount["work-account", default: []].append(snap)
        }

        // 5h: default 20*(1-0.5)=10, apple 20*(1-0.8)=4 → remaining 14 of 40.
        let five = state.aggregateRemaining(window: .fiveHour, now: now)
        XCTAssertEqual(five.total, 40, accuracy: 1e-9,
                       "both accounts must weigh into the 5h aggregate")
        XCTAssertEqual(five.remaining, 14, accuracy: 1e-9)

        // weekly: default 20*(1-0.2)=16, apple 20*(1-0.1)=18 → remaining 34 of 40.
        let weekly = state.aggregateRemaining(window: .sevenDay, now: now)
        XCTAssertEqual(weekly.total, 40, accuracy: 1e-9,
                       "OAuth-only account must weigh into the weekly aggregate")
        XCTAssertEqual(weekly.remaining, 34, accuracy: 1e-9)

        // weekly sonnet: only apple has it (5%) → remaining 20*(1-0.05)=19 of 20.
        let sonnet = state.aggregateRemaining(window: .sevenDaySonnet, now: now)
        XCTAssertEqual(sonnet.total, 20, accuracy: 1e-9,
                       "OAuth sonnet window must contribute to the aggregate")
        XCTAssertEqual(sonnet.remaining, 19, accuracy: 1e-9)
    }

    /// End-to-end through refreshUsage: "default" has a statusline rate_limits file;
    /// "work-account" has statusline captures that carry NO rate_limits, and OAuth
    /// is available ONLY for work-account. After refresh the Overall aggregate must
    /// reflect both accounts for every window.
    func testRefreshUsageFoldsOAuthLimitsForStatuslineLessAccount() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)  // 2025-06-15T16:53:20Z
        let future = "2025-06-15T18:00:00Z"

        let defaultDir = root.appendingPathComponent("default")
        let appleDir = root.appendingPathComponent("apple")
        for dir in [defaultDir, appleDir] {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("grove/usage"), withIntermediateDirectories: true)
        }
        // default: statusline WITH rate_limits (5h=50%).
        try """
        {"capturedAt":"2025-06-15T16:50:00Z","raw":{"session_id":"d1",
          "workspace":{"current_dir":"/ws/d"},
          "rate_limits":{"five_hour":{"used_percentage":50,"resets_at":"\(future)"}}}}
        """.write(to: defaultDir.appendingPathComponent("grove/usage/d1.json"),
                  atomically: true, encoding: .utf8)
        // work-account: statusline with NO rate_limits (lightly-used account).
        try """
        {"capturedAt":"2025-06-15T16:50:00Z","raw":{"session_id":"a1",
          "workspace":{"current_dir":"/ws/a"}}}
        """.write(to: appleDir.appendingPathComponent("grove/usage/a1.json"),
                  atomically: true, encoding: .utf8)

        let state = makeState()
        state.config = GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}", projects: [],
            accounts: [AccountConfig(name: "default", configDir: defaultDir.path),
                       AccountConfig(name: "work-account", configDir: appleDir.path)])
        state.tierOverride = ["default": "default_claude_max_20x",
                              "work-account": "default_claude_max_20x"]
        // OAuth available ONLY for work-account's dir.
        let appleResolved = appleDir.path
        state.oauthLimitsOverride = { @Sendable dir, _ in
            dir == appleResolved
                ? OAuthUsage(fiveHour: OAuthWindow(utilization: 80, resetsAt: future),
                             sevenDay: OAuthWindow(utilization: 10, resetsAt: future),
                             sevenDaySonnet: OAuthWindow(utilization: 5, resetsAt: future),
                             sevenDayOpus: nil)
                : nil
        }

        await state.refreshUsage(now: now)

        // work-account must now have an OAuth-sourced capture in its snapshots.
        let appleSnaps = state.snapshotsByAccount["work-account"] ?? []
        XCTAssertTrue(appleSnaps.contains { $0.sessionId == "oauth" },
                      "OAuth snapshot must be folded into work-account's captures")

        // 5h aggregate: both accounts contribute (default 50%, apple 80%).
        let five = state.aggregateRemaining(window: .fiveHour, now: now)
        XCTAssertEqual(five.total, 40, accuracy: 1e-9,
                       "Overall 5h must consolidate BOTH accounts, not just default")
        XCTAssertEqual(five.remaining, 14, accuracy: 1e-9)  // 20*0.5 + 20*0.2

        // weekly aggregate: default has no statusline 7d, apple OAuth=10%.
        let weekly = state.aggregateRemaining(window: .sevenDay, now: now)
        XCTAssertEqual(weekly.total, 20, accuracy: 1e-9,
                       "work-account's OAuth weekly must contribute to Overall")
        XCTAssertEqual(weekly.remaining, 18, accuracy: 1e-9)  // 20*(1-0.1)
    }

    /// Hardening: when the OAuth snapshot is the NEWEST capture but lacks the 5h
    /// window (API returned only weekly windows for a lightly-used account), the
    /// account must still contribute its WEEKLY window to the aggregate — the
    /// per-window resolution must not be poisoned by the OAuth snapshot's nil 5h.
    func testOAuthWeeklyOnlyAccountStillCountsForWeekly() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let future = "2025-06-15T18:00:00Z"
        let state = makeState()
        state.config = GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}", projects: [],
            accounts: [AccountConfig(name: "default", configDir: root.appendingPathComponent("d").path),
                       AccountConfig(name: "work-account", configDir: root.appendingPathComponent("a").path)])
        state.tierOverride = ["default": "default_claude_max_20x",
                              "work-account": "default_claude_max_20x"]

        // apple: statusline carries nothing; OAuth has weekly ONLY (no five_hour).
        state.snapshotsByAccount = [
            "default": [UsageSnapshot(accountName: "default", sessionId: "s1", capturedAt: now,
                                      cwd: nil, modelId: nil, modelDisplayName: nil, effort: nil,
                                      contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                                      fiveHour: CapturedWindow(usedPercentage: 30, resetsAt: future),
                                      sevenDay: CapturedWindow(usedPercentage: 40, resetsAt: future))],
            "work-account": [statuslineNoLimits(account: "work-account", now: now)],
        ]
        let oauthWeeklyOnly = OAuthUsage(
            fiveHour: nil,
            sevenDay: OAuthWindow(utilization: 10, resetsAt: future),
            sevenDaySonnet: nil, sevenDayOpus: nil)
        if let snap = AppState.oauthSnapshot(accountName: "work-account",
                                             usage: oauthWeeklyOnly, now: now) {
            state.snapshotsByAccount["work-account", default: []].append(snap)
        }

        // 5h: only default has data → Overall 5h == default (correct, apple has none).
        let five = state.aggregateRemaining(window: .fiveHour, now: now)
        XCTAssertEqual(five.total, 20, accuracy: 1e-9)
        XCTAssertEqual(five.remaining, 14, accuracy: 1e-9)  // 20*(1-0.3)

        // weekly: BOTH contribute (default 40%, apple OAuth 10%).
        let weekly = state.aggregateRemaining(window: .sevenDay, now: now)
        XCTAssertEqual(weekly.total, 40, accuracy: 1e-9,
                       "apple's OAuth-only weekly must still consolidate into Overall")
        XCTAssertEqual(weekly.remaining, 30, accuracy: 1e-9)  // 20*0.6 + 20*0.9
    }

    /// Robustness of the statusline-first / OAuth-fallback per-window resolver: an
    /// account whose NEWEST snapshot is the OAuth one (with a nil 5h) must still
    /// surface its STATUSLINE 5h window — the old "newest snapshot wins" fallback
    /// would have read nil from the OAuth capture and dropped a real 5h reading.
    func testStatuslineWindowPreferredOverNewerOAuthSnapshotMissingThatWindow() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let future = "2025-06-15T18:00:00Z"
        // Statusline 5h captured BEFORE the OAuth snapshot; OAuth (newest) has 5h=nil.
        let statusline = UsageSnapshot(
            accountName: "a", sessionId: "s1",
            capturedAt: now.addingTimeInterval(-300), cwd: nil, modelId: nil,
            modelDisplayName: nil, effort: nil, contextUsedPercentage: nil,
            totalInputTokens: nil, totalCostUSD: nil,
            fiveHour: CapturedWindow(usedPercentage: 25, resetsAt: future),
            sevenDay: CapturedWindow(usedPercentage: 60, resetsAt: future))
        let oauth = UsageSnapshot(
            accountName: "a", sessionId: "oauth", capturedAt: now, cwd: nil,
            modelId: nil, modelDisplayName: nil, effort: nil, contextUsedPercentage: nil,
            totalInputTokens: nil, totalCostUSD: nil,
            fiveHour: nil,  // OAuth had no five_hour this poll
            sevenDay: CapturedWindow(usedPercentage: 10, resetsAt: future),
            sevenDaySonnet: CapturedWindow(usedPercentage: 5, resetsAt: future))
        let snaps = [statusline, oauth]

        // 5h resolves to the statusline value (25%), NOT nil.
        XCTAssertEqual(accountWindow(snaps, { $0.fiveHour }, now: now)?.usedPercentage, 25)
        // weekly prefers the statusline value (60%) over the OAuth fallback (10%).
        XCTAssertEqual(accountWindow(snaps, { $0.sevenDay }, now: now)?.usedPercentage, 60)
        // sonnet has no statusline value → falls back to OAuth (5%).
        XCTAssertEqual(accountWindow(snaps, { $0.sevenDaySonnet }, now: now)?.usedPercentage, 5)
    }

    /// A FRESH OAuth window must win over a STALE statusline window: the statusline
    /// weekly already reset (resets_at in the past), so its used% is stale, while
    /// the OAuth weekly is current. The resolver must surface the OAuth value.
    func testFreshOAuthBeatsStaleStatuslineWindow() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let past = "2025-06-15T10:00:00Z"   // before `now`
        let future = "2025-06-15T18:00:00Z" // after `now`
        let statuslineStale = UsageSnapshot(
            accountName: "a", sessionId: "s1", capturedAt: now.addingTimeInterval(-600),
            cwd: nil, modelId: nil, modelDisplayName: nil, effort: nil,
            contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
            fiveHour: nil,
            sevenDay: CapturedWindow(usedPercentage: 90, resetsAt: past))  // stale
        let oauthFresh = UsageSnapshot(
            accountName: "a", sessionId: "oauth", capturedAt: now, cwd: nil,
            modelId: nil, modelDisplayName: nil, effort: nil, contextUsedPercentage: nil,
            totalInputTokens: nil, totalCostUSD: nil,
            fiveHour: nil,
            sevenDay: CapturedWindow(usedPercentage: 12, resetsAt: future))  // fresh
        let resolved = accountWindow([statuslineStale, oauthFresh], { $0.sevenDay }, now: now)
        XCTAssertEqual(resolved?.usedPercentage, 12,
                       "fresh OAuth weekly must win over a stale statusline weekly")
    }
}
