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
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let resets = ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600))
        s.oauthLimitsOverride = { cfg, _ in
            cfg == dir.path
                ? OAuthUsage(fiveHour: OAuthWindow(utilization: 22, resetsAt: resets),
                             sevenDay: OAuthWindow(utilization: 4, resetsAt: resets),
                             sevenDaySonnet: nil, sevenDayOpus: nil)
                : nil
        }
        await s.refreshUsage(now: now)
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
        // OAuth is now ALWAYS consulted (it's the only source of the Sonnet window).
        var oauthCalled = false
        s.oauthLimitsOverride = { _, _ in
            oauthCalled = true
            return OAuthUsage(fiveHour: OAuthWindow(utilization: 12, resetsAt: resets),
                              sevenDay: OAuthWindow(utilization: 5, resetsAt: resets),
                              sevenDaySonnet: OAuthWindow(utilization: 8, resetsAt: resets),
                              sevenDayOpus: nil)
        }
        await s.refreshUsage(now: now)
        XCTAssertTrue(oauthCalled, "OAuth is fetched for every account (Sonnet source)")
        let snaps = s.snapshotsByAccount["default"] ?? []
        // The statusline capture is kept (history) AND the OAuth capture is appended.
        XCTAssertTrue(snaps.contains { $0.fiveHour?.usedPercentage == 30 }, "statusline capture kept")
        XCTAssertTrue(snaps.contains { $0.sevenDaySonnet?.usedPercentage == 8 }, "OAuth Sonnet folded in")
        // currentWindow prefers the latest (OAuth) capture for the live 5h reading.
        XCTAssertEqual(currentWindow(snaps, { $0.sevenDaySonnet }, now: now)?.usedPercentage, 8)
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
}
