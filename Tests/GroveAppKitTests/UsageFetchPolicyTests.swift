import XCTest
import GroveCore
@testable import GroveAppKit

/// Opening the panel is the gesture that means "show me current limits": ONE OAuth
/// request per account, then nothing until the user asks again. The old behaviour
/// re-fetched on every 15s liveness tick, which both burned rate limit and — because
/// the synthetic OAuth capture is memory-only and rebuilt from disk each tick — made
/// the OAuth-only model bar blink out whenever a fetch failed or was suppressed.
@MainActor
final class UsageFetchPolicyTests: XCTestCase {
    private var root: URL!
    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    override func setUp() async throws {
        root = try FixtureLite.tempDir("fetch-policy")
        dir = try FixtureLite.tempDir("fetch-policy-acct")
    }

    private func state() -> AppState {
        let s = AppState(configStore: ConfigStore(url: root.appendingPathComponent("c.json")))
        s.canonicalDirOverride = root.appendingPathComponent("canonical").path
        s.usageLedgerStoreDirOverride = root.appendingPathComponent("ledger").path
        s.config.accounts = [AccountConfig(name: "apple", configDir: dir.path)]
        return s
    }

    /// Counts provider calls and can be switched to failing mid-test.
    private final class Provider {
        var calls = 0
        var failing = false
        let resets: String
        let fetchedAt: Date
        init(resets: String, fetchedAt: Date) { self.resets = resets; self.fetchedAt = fetchedAt }
        func usage() -> OAuthUsage? {
            calls += 1
            if failing { return nil }
            return OAuthUsage(fiveHour: OAuthWindow(utilization: 22, resetsAt: resets),
                              sevenDay: OAuthWindow(utilization: 4, resetsAt: resets),
                              sevenDaySonnet: nil, sevenDayOpus: nil,
                              weeklyScoped: OAuthScopedWindow(utilization: 100, resetsAt: resets,
                                                              modelDisplayName: "Fable"),
                              fetchedAt: fetchedAt)
        }
    }

    private func install(_ provider: Provider, on s: AppState) {
        s.oauthLimitsOverride = { _, _ in provider.usage() }
    }

    private func resets() -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(86_400))
    }

    // MARK: - cadence

    func testLivenessTicksDoNotTouchOAuth() async throws {
        let s = state()
        let provider = Provider(resets: resets(), fetchedAt: now)
        install(provider, on: s)
        s.isPanelOpen = true                     // panel open must NOT imply a fetch
        await s.refreshUsage(now: now, oauth: .skip)
        await s.refreshUsage(now: now, oauth: .skip)
        XCTAssertEqual(provider.calls, 0, "the 15s liveness tick must never hit the API")
    }

    func testPanelOpenFetchesExactlyOncePerAccount() async throws {
        let s = state()
        let provider = Provider(resets: resets(), fetchedAt: now)
        install(provider, on: s)
        await s.refreshUsage(now: now, oauth: .fetch)
        XCTAssertEqual(provider.calls, 1)
    }

    func testSkipTickLeavesTheSpinnerAlone() async throws {
        let s = state()
        install(Provider(resets: resets(), fetchedAt: now), on: s)
        await s.refreshUsage(now: now, oauth: .skip)
        XCTAssertFalse(s.isRefreshingUsage,
                       "a local-only tick must not flash the loading indicator")
    }

    /// `oauthLiveEnabled` switches off the AUTOMATIC pass…
    func testDisabledOAuthSkipsTheAutomaticFetch() async throws {
        let s = state()
        let provider = Provider(resets: resets(), fetchedAt: now)
        install(provider, on: s)
        s.config.usage.oauthLiveEnabled = false
        await s.refreshUsage(now: now, oauth: .fetch)
        XCTAssertEqual(provider.calls, 0)
    }

    /// …but never the button. A refresh control that silently did nothing would be
    /// worse than no control at all.
    func testButtonStillFetchesWithAutomaticFetchDisabled() async throws {
        let s = state()
        let provider = Provider(resets: resets(), fetchedAt: now)
        install(provider, on: s)
        s.config.usage.oauthLiveEnabled = false
        await s.refreshUsage(now: now, oauth: .force)
        XCTAssertEqual(provider.calls, 1)
    }

    // MARK: - retention (the disappearing model bar)

    /// The model-scoped bar comes ONLY from the OAuth response — the live API returns
    /// null for every top-level per-model key. So a tick that did not fetch must reuse
    /// the last known capture instead of dropping it.
    func testModelWindowSurvivesATickThatDoesNotFetch() async throws {
        let s = state()
        let provider = Provider(resets: resets(), fetchedAt: now)
        install(provider, on: s)
        await s.refreshUsage(now: now, oauth: .fetch)
        XCTAssertEqual(s.accountLimitInputs(now: now).first?.scopedModel, "Fable",
                       "precondition: the fetch produced a Fable window")

        await s.refreshUsage(now: now.addingTimeInterval(15), oauth: .skip)
        XCTAssertEqual(s.accountLimitInputs(now: now).first?.scopedModel, "Fable",
                       "a local-only tick must not drop the Fable window")
    }

    /// A 429 backoff (provider returns nil) must not blank the bar either.
    func testModelWindowSurvivesAFailedFetch() async throws {
        let s = state()
        let provider = Provider(resets: resets(), fetchedAt: now)
        install(provider, on: s)
        await s.refreshUsage(now: now, oauth: .fetch)
        provider.failing = true
        await s.refreshUsage(now: now.addingTimeInterval(200), oauth: .force)
        XCTAssertEqual(s.accountLimitInputs(now: now).first?.scopedModel, "Fable",
                       "a failed refresh must keep showing the last known limits")
    }

    /// Retained data must keep its ORIGINAL timestamp, so the footer reports the real age.
    func testRetainedCaptureKeepsItsOriginalFetchTime() async throws {
        let s = state()
        let fetched = now.addingTimeInterval(-600)
        let provider = Provider(resets: resets(), fetchedAt: fetched)
        install(provider, on: s)
        await s.refreshUsage(now: now, oauth: .fetch)
        await s.refreshUsage(now: now.addingTimeInterval(15), oauth: .skip)
        XCTAssertEqual(s.usageDataAsOf, fetched,
                       "retention must not backdate or refresh the age")
    }

    /// An account removed from the config must not be resurrected by the retained copy.
    func testRemovedAccountIsNotResurrected() async throws {
        let s = state()
        let provider = Provider(resets: resets(), fetchedAt: now)
        install(provider, on: s)
        await s.refreshUsage(now: now, oauth: .fetch)
        s.config.accounts = []
        await s.refreshUsage(now: now.addingTimeInterval(15), oauth: .skip)
        XCTAssertTrue(s.snapshotsByAccount["apple"]?.isEmpty ?? true)
    }
}
