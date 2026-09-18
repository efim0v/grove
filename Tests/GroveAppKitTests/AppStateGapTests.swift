import XCTest
import GroveCore
@testable import GroveAppKit

@MainActor
final class AppStateGapTests: XCTestCase {
    private var configURL: URL!
    private var root: URL!

    override func setUp() async throws {
        root = try FixtureLite.tempDir("appstate-gap")
        configURL = root.appendingPathComponent("config.json")
    }

    private func state(_ runner: ScriptedRunner = ScriptedRunner(responses: ["ping": .ok("PONG")])) -> AppState {
        let s = AppState(configStore: ConfigStore(url: configURL))
        s.cmuxOverride = stubbedCmux(runner)
        s.canonicalDirOverride = root.appendingPathComponent("canonical").path
        s.usageLedgerStoreDirOverride = root.appendingPathComponent("ledger").path
        return s
    }

    func testProjectCrudModelEffortAndSelection() {
        let s = state()
        s.addProject(at: "/tmp/grove-demo")
        let id = s.selectedProjectID!
        XCTAssertEqual(s.selectedProject?.name, "grove-demo")
        s.setProjectModel(projectID: id, model: "claude-opus-4-8")
        s.setProjectEffort(projectID: id, effort: "high")
        XCTAssertEqual(s.selectedProject?.defaultModel, "claude-opus-4-8")
        XCTAssertEqual(s.selectedProject?.defaultEffort, "high")
        s.setProjectModel(projectID: id, model: "")     // empty clears
        s.setProjectEffort(projectID: id, effort: "")
        XCTAssertNil(s.selectedProject?.defaultModel)
        XCTAssertNil(s.selectedProject?.defaultEffort)
        s.updateProject(ProjectConfig(name: "ghost", path: "/x"))   // unknown id -> no-op
        XCTAssertEqual(s.config.projects.count, 1)
        s.removeProject(id: id)
        XCTAssertTrue(s.config.projects.isEmpty)
        XCTAssertNil(s.selectedProjectID)
    }

    func testAccountCrudRejectsDuplicates() {
        let s = state()
        // addAccount auto-installs a statusline (Phase 5A); keep its dir + script writes
        // inside temp dirs, never the real ~/.claude-accounts / ~/Library.
        s.accountsRootOverride = root.appendingPathComponent("accts").path
        s.statuslineScriptDirOverride = root.appendingPathComponent("bin-crud").path
        let initial = s.config.accounts.count
        s.addAccount(name: "work")
        XCTAssertTrue(s.config.accounts.contains { $0.name == "work" })
        XCTAssertEqual(s.config.accounts.count, initial + 1)
        s.addAccount(name: "work")        // duplicate
        XCTAssertNotNil(s.actionError)
        XCTAssertEqual(s.config.accounts.count, initial + 1, "duplicate not added")
        s.removeAccount(name: "work")
        XCTAssertFalse(s.config.accounts.contains { $0.name == "work" })
    }

    func testWorkspacesRootTemplatePersists() {
        let s = state()
        s.setWorkspacesRootTemplate("~/Code/{project}")
        XCTAssertEqual(s.config.workspacesRootTemplate, "~/Code/{project}")
    }

    func testGoToCmuxAndOpenShellRecordCalls() async {
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let s = state(runner)
        await s.goToCmux(CmuxWorkspace(id: "ws-1", title: "t", currentDirectory: "/a"))
        XCTAssertEqual(runner.calls(startingWith: "select-workspace").first?.args,
                       ["select-workspace", "--workspace", "ws-1"])
        await s.openCmuxShell(cwd: "/a", title: "shell")
        XCTAssertEqual(runner.calls(startingWith: "new-workspace").count, 1)
    }

    func testAggregateRemainingUsesLatestCaptureAndTierWeight() {
        let s = state()
        s.config.accounts = [AccountConfig(name: "a", configDir: "/tmp/a")]
        s.tierOverride = ["a": "default_claude_max_5x"]
        s.snapshotsByAccount = ["a": [UsageSnapshot(
            accountName: "a", sessionId: "s", capturedAt: Date(), cwd: nil, modelId: nil,
            modelDisplayName: nil, effort: nil, contextUsedPercentage: nil, totalInputTokens: nil,
            totalCostUSD: nil, fiveHour: CapturedWindow(usedPercentage: 40, resetsAt: nil),
            sevenDay: nil)]]
        let agg = s.aggregateRemaining(window: .fiveHour, now: Date())
        XCTAssertEqual(agg.total, 5, accuracy: 1e-9)
        XCTAssertEqual(agg.remaining, 5 * 0.6, accuracy: 1e-9)
    }

    func testAggregateResetIsTheSoonestUpcomingAcrossAccounts() {
        let s = state()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let iso = ISO8601DateFormatter()
        let inOneHour = iso.string(from: now.addingTimeInterval(3_600))
        let inHalfHour = iso.string(from: now.addingTimeInterval(1_800))   // sooner
        func snap(_ acct: String, _ resets: String) -> UsageSnapshot {
            UsageSnapshot(accountName: acct, sessionId: "s", capturedAt: now, cwd: nil,
                          modelId: nil, modelDisplayName: nil, effort: nil,
                          contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                          fiveHour: CapturedWindow(usedPercentage: 50, resetsAt: resets), sevenDay: nil)
        }
        s.config.accounts = [AccountConfig(name: "a", configDir: "/tmp/a"),
                             AccountConfig(name: "b", configDir: "/tmp/b")]
        s.snapshotsByAccount = ["a": [snap("a", inOneHour)], "b": [snap("b", inHalfHour)]]
        let reset = s.aggregateReset(window: .fiveHour, now: now)
        XCTAssertEqual(reset?.timeIntervalSince1970 ?? 0,
                       now.addingTimeInterval(1_800).timeIntervalSince1970, accuracy: 1.0,
                       "the chip shows the next account to refresh, not the latest")
    }

    func testShortModelNameStripsClaudePrefix() {
        XCTAssertEqual(shortModelName("claude-sonnet-4-6"), "sonnet-4-6")
        XCTAssertEqual(shortModelName("claude-opus-4-8"), "opus-4-8")
        XCTAssertEqual(shortModelName("gpt-x"), "gpt-x")       // untouched
    }

    func testOAuthSnapshotMapsUtilizationPercentAndDropsEmpty() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        // utilization is already a 0–100 percentage (verified live); carried as-is,
        // resets_at preserved.
        let snap = AppState.oauthSnapshot(accountName: "a", usage: OAuthUsage(
            fiveHour: OAuthWindow(utilization: 0, resetsAt: "x"),
            sevenDay: OAuthWindow(utilization: 2, resetsAt: nil),
            sevenDaySonnet: nil, sevenDayOpus: nil), now: now)
        XCTAssertEqual(snap?.fiveHour?.usedPercentage, 0)
        XCTAssertEqual(snap?.sevenDay?.usedPercentage, 2)
        XCTAssertEqual(snap?.fiveHour?.resetsAt, "x")
        // Out-of-range values are clamped.
        let clamped = AppState.oauthSnapshot(accountName: "a", usage: OAuthUsage(
            fiveHour: OAuthWindow(utilization: 130, resetsAt: nil),
            sevenDay: nil, sevenDaySonnet: nil, sevenDayOpus: nil), now: now)
        XCTAssertEqual(clamped?.fiveHour?.usedPercentage, 100)
        // No windows → no synthetic capture.
        XCTAssertNil(AppState.oauthSnapshot(accountName: "a", usage: OAuthUsage(
            fiveHour: nil, sevenDay: nil, sevenDaySonnet: nil, sevenDayOpus: nil), now: now))
    }

    func testRefreshUsageFallsBackToOAuthWhenStatuslineHasNoLimits() async throws {
        let s = state()
        let dir = try FixtureLite.tempDir("oauth-acct")
        s.config.accounts = [AccountConfig(name: "apple", configDir: dir.path)]
        s.snapshotsByAccount = [:]                       // no statusline captures
        s.config.usage.oauthLiveEnabled = true           // opt into the OAuth poll
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let resets = ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600))
        s.oauthLimitsOverride = { cfg, _ in
            cfg == dir.path
                ? OAuthUsage(fiveHour: OAuthWindow(utilization: 22, resetsAt: resets),
                             sevenDay: OAuthWindow(utilization: 4, resetsAt: resets),
                             sevenDaySonnet: nil, sevenDayOpus: nil)
                : nil
        }
        await s.refreshUsage(now: now, oauth: .fetch)
        let snaps = s.snapshotsByAccount["apple"] ?? []
        XCTAssertEqual(snaps.last?.sessionId, "oauth")
        XCTAssertEqual(snaps.last?.fiveHour?.usedPercentage, 22)
        XCTAssertEqual(snaps.last?.sevenDay?.usedPercentage, 4)
        // And the aggregate/chip now see apple's limits.
        s.tierOverride = ["apple": "default_claude_max_5x"]
        XCTAssertEqual(s.aggregateRemaining(window: .fiveHour, now: now).remaining,
                       5 * 0.78, accuracy: 1e-9)
    }

    func testRefreshUsagePrefersOAuthOverStatuslineAndKeepsHistory() async throws {
        let s = state()
        let dir = try FixtureLite.tempDir("oauth-primary")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        // Seed a REAL statusline capture on disk (the refresh rebuilds snaps from disk).
        let usageDir = dir.appendingPathComponent("grove/usage")
        try FileManager.default.createDirectory(at: usageDir, withIntermediateDirectories: true)
        let resets = ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600))
        let capturedAt = ISO8601DateFormatter().string(from: now)
        let capture = """
        {"capturedAt":"\(capturedAt)","raw":{"session_id":"s",
         "rate_limits":{"five_hour":{"used_percentage":30,"resets_at":"\(resets)"}}}}
        """
        try capture.write(to: usageDir.appendingPathComponent("c.json"), atomically: true, encoding: .utf8)
        s.config.accounts = [AccountConfig(name: "default", configDir: dir.path)]
        s.config.usage.oauthLiveEnabled = true           // opt into the OAuth poll
        // OAuth is now ALWAYS consulted (it's the only source of the Sonnet window).
        var oauthCalled = false
        s.oauthLimitsOverride = { _, _ in
            oauthCalled = true
            return OAuthUsage(fiveHour: OAuthWindow(utilization: 12, resetsAt: resets),
                              sevenDay: OAuthWindow(utilization: 5, resetsAt: resets),
                              sevenDaySonnet: OAuthWindow(utilization: 8, resetsAt: resets),
                              sevenDayOpus: nil)
        }
        await s.refreshUsage(now: now, oauth: .fetch)
        XCTAssertTrue(oauthCalled, "OAuth is fetched for every account (Sonnet source)")
        let snaps = s.snapshotsByAccount["default"] ?? []
        // The statusline capture is kept (history) AND the OAuth capture is appended.
        XCTAssertTrue(snaps.contains { $0.fiveHour?.usedPercentage == 30 }, "statusline capture kept")
        XCTAssertTrue(snaps.contains { $0.sevenDaySonnet?.usedPercentage == 8 }, "OAuth Sonnet folded in")
        // currentWindow prefers the latest (OAuth) capture for the live 5h reading.
        XCTAssertEqual(currentWindow(snaps, { $0.sevenDaySonnet }, now: now)?.usedPercentage, 8)
    }

    /// `oauthLiveEnabled` gates the AUTOMATIC pass: with it off, opening the panel
    /// must not consult OAuth. (An explicit refresh-button press still does — see
    /// AppStateUsageFreshnessTests.) The mere presence of a provider override must
    /// never force a fetch either, or the background timer would hit the keychain
    /// before any user gesture.
    func testRefreshUsageSkipsAutomaticOAuthWhenFlagOff() async throws {
        let s = state()
        let dir = try FixtureLite.tempDir("oauth-gate-off")
        s.config.accounts = [AccountConfig(name: "apple", configDir: dir.path)]
        s.snapshotsByAccount = [:]
        s.isPanelOpen = false
        s.config.usage.oauthLiveEnabled = false
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let resets = ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600))
        var oauthCalled = false
        s.oauthLimitsOverride = { _, _ in
            oauthCalled = true
            return OAuthUsage(fiveHour: OAuthWindow(utilization: 22, resetsAt: resets),
                              sevenDay: nil, sevenDaySonnet: nil, sevenDayOpus: nil)
        }
        await s.refreshUsage(now: now, oauth: .fetch)
        XCTAssertFalse(oauthCalled,
            "the automatic pass must not fetch when oauthLiveEnabled is off")
        XCTAssertTrue((s.snapshotsByAccount["apple"] ?? []).isEmpty,
            "No OAuth snapshot should be folded in when OAuth is gated off")
    }

    /// The panel's open/closed state no longer gates the fetch — the CALLER's policy
    /// does. A `.fetch` pass works with the panel closed, which is what lets an account
    /// with no statusline capture get its limits at all.
    func testRefreshUsageFetchesOAuthOnDemandEvenWithPanelClosed() async throws {
        let s = state()
        let dir = try FixtureLite.tempDir("oauth-gate-on")
        s.config.accounts = [AccountConfig(name: "apple", configDir: dir.path)]
        s.snapshotsByAccount = [:]
        s.isPanelOpen = false
        s.config.usage.oauthLiveEnabled = true
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let resets = ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600))
        var oauthCalled = false
        s.oauthLimitsOverride = { _, _ in
            oauthCalled = true
            return OAuthUsage(fiveHour: OAuthWindow(utilization: 22, resetsAt: resets),
                              sevenDay: OAuthWindow(utilization: 4, resetsAt: resets),
                              sevenDaySonnet: nil, sevenDayOpus: nil)
        }
        await s.refreshUsage(now: now, oauth: .fetch)
        XCTAssertTrue(oauthCalled,
            "a .fetch pass must reach OAuth regardless of the panel's state")
        XCTAssertEqual((s.snapshotsByAccount["apple"] ?? []).last?.fiveHour?.usedPercentage, 22)
    }

    /// Phase 5A launch reconcile: auto-installs the statusline wrapper for every
    /// configured account that is not yet monitored (e.g. accounts created before 5A,
    /// or an icloud account that never had monitoring enabled), preserving each
    /// account's original command. Accounts already monitored are left untouched, so a
    /// user who explicitly disabled monitoring is not re-enabled on the next launch.
    /// reconcileMonitoring fires I/O off-main (Task.detached), so we await completion.
    func testReconcileMonitoringInstallsForUnmonitoredAccountsOnly() async throws {
        let s = state()
        let binDir = root.appendingPathComponent("reconcile-bin")
        s.statuslineScriptDirOverride = binDir.path
        let dirA = root.appendingPathComponent("recon-a")   // never monitored
        let dirB = root.appendingPathComponent("recon-b")   // already monitored
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        let originalA = "/bin/echo status-a"
        try #"{"statusLine":{"type":"command","command":"\#(originalA)"}}"#
            .write(to: dirA.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let originalB = "/bin/echo status-b"
        try #"{"statusLine":{"type":"command","command":"\#(originalB)"}}"#
            .write(to: dirB.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        s.config.accounts = [
            AccountConfig(name: "a", configDir: dirA.path),
            AccountConfig(name: "b", configDir: dirB.path, monitoring: true),
        ]

        s.reconcileMonitoring()

        // reconcileMonitoring dispatches I/O to a Task.detached; yield until task completes.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            await Task.yield()
            if s.config.accounts.first(where: { $0.name == "a" })?.monitoring == true { break }
        }

        XCTAssertNil(s.actionError)
        // Account a: installed, original preserved, marked monitored.
        let a = try XCTUnwrap(s.config.accounts.first { $0.name == "a" })
        XCTAssertEqual(a.monitoring, true)
        XCTAssertEqual(a.savedStatusline, originalA)
        let aObj = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dirA.appendingPathComponent("settings.json"))) as? [String: Any]
        XCTAssertTrue(((aObj?["statusLine"] as? [String: Any])?["command"] as? String)?
            .contains("grove-statusline-") == true)
        // Account b: already monitored → left untouched (settings.json still the original).
        let bObj = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dirB.appendingPathComponent("settings.json"))) as? [String: Any]
        XCTAssertEqual((bObj?["statusLine"] as? [String: Any])?["command"] as? String, originalB,
                       "an already-monitored account must not be re-installed by reconcile")
    }

    func testInstallAndDisableMonitoringToggleFlag() throws {
        let s = state()
        s.statuslineScriptDirOverride = root.appendingPathComponent("bin").path
        let dir = root.appendingPathComponent("acct-claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        s.config.accounts = [AccountConfig(name: "work", configDir: dir.path)]
        s.installMonitoring(s.config.accounts[0])
        XCTAssertTrue(s.config.accounts[0].monitoring)
        s.disableMonitoring(s.config.accounts[0])
        XCTAssertFalse(s.config.accounts[0].monitoring)
    }

    /// FIX 1: reconcileMonitoring must NOT re-enable an explicitly-disabled account.
    /// An account with monitoring=false AND monitoringDisabledByUser=true is skipped.
    /// An account with monitoring=false AND monitoringDisabledByUser=false (never monitored) IS installed.
    /// reconcileMonitoring fires file I/O off-main (Task.detached), so we await completion.
    func testReconcileMonitoringDoesNotReEnableExplicitlyDisabledAccount() async throws {
        let s = state()
        let binDir = root.appendingPathComponent("fix1-bin")
        s.statuslineScriptDirOverride = binDir.path

        // Account A: never monitored (disabledByUser=false) — should be installed.
        let dirA = root.appendingPathComponent("fix1-a")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try #"{"statusLine":{"type":"command","command":"/bin/echo status-a"}}"#
            .write(to: dirA.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        // Account B: user explicitly disabled monitoring (disabledByUser=true) — must NOT be installed.
        let dirB = root.appendingPathComponent("fix1-b")
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        let originalB = "/bin/echo status-b"
        try #"{"statusLine":{"type":"command","command":"\#(originalB)"}}"#
            .write(to: dirB.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        s.config.accounts = [
            AccountConfig(name: "never-monitored", configDir: dirA.path,
                          monitoring: false, monitoringDisabledByUser: false),
            AccountConfig(name: "user-disabled", configDir: dirB.path,
                          monitoring: false, monitoringDisabledByUser: true),
        ]

        s.reconcileMonitoring()

        // reconcileMonitoring dispatches I/O to a Task.detached; yield back to run loop
        // long enough for the utility task + MainActor.run hop to complete.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            await Task.yield()
            if s.config.accounts.first(where: { $0.name == "never-monitored" })?.monitoring == true { break }
        }

        // Account A (never monitored): should be installed and marked monitored.
        let acctA = try XCTUnwrap(s.config.accounts.first { $0.name == "never-monitored" })
        XCTAssertTrue(acctA.monitoring, "never-monitored account should be auto-installed by reconcile")

        // Account B (user disabled): must NOT be re-enabled.
        let acctB = try XCTUnwrap(s.config.accounts.first { $0.name == "user-disabled" })
        XCTAssertFalse(acctB.monitoring, "explicitly-disabled account must not be re-enabled by reconcile")
        // settings.json for B must still contain the original command, not the grove wrapper.
        let bObj = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dirB.appendingPathComponent("settings.json"))) as? [String: Any]
        XCTAssertEqual((bObj?["statusLine"] as? [String: Any])?["command"] as? String, originalB,
                       "reconcile must not overwrite settings.json of an explicitly-disabled account")
    }

    /// FIX 1: disableMonitoring sets monitoringDisabledByUser=true; installMonitoring/enableMonitoring clears it.
    func testDisableMonitoringSetsDisabledByUserFlag() throws {
        let s = state()
        s.statuslineScriptDirOverride = root.appendingPathComponent("fix1-toggle-bin").path
        let dir = root.appendingPathComponent("fix1-toggle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        s.config.accounts = [AccountConfig(name: "work", configDir: dir.path)]

        // Install first so disableMonitoring has something to uninstall.
        s.installMonitoring(s.config.accounts[0])
        XCTAssertTrue(s.config.accounts[0].monitoring)
        XCTAssertFalse(s.config.accounts[0].monitoringDisabledByUser,
                       "install must clear monitoringDisabledByUser")

        // Disable: must set the flag.
        s.disableMonitoring(s.config.accounts[0])
        XCTAssertFalse(s.config.accounts[0].monitoring)
        XCTAssertTrue(s.config.accounts[0].monitoringDisabledByUser,
                      "disableMonitoring must set monitoringDisabledByUser=true")

        // Re-install via installMonitoring: must clear the flag.
        s.installMonitoring(s.config.accounts[0])
        XCTAssertTrue(s.config.accounts[0].monitoring)
        XCTAssertFalse(s.config.accounts[0].monitoringDisabledByUser,
                       "re-installing must clear monitoringDisabledByUser")
    }
}
