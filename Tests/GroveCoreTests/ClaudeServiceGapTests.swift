import XCTest
@testable import GroveCore

final class ClaudeServiceGapTests: XCTestCase {
    private let fm = FileManager.default
    private var dir: URL!
    private let claude = ClaudeService()

    override func setUpWithError() throws { dir = try Fixture.tempDir("claude-gap") }

    func testIdentityForCustomAccountReadsConfigDirClaudeJson() throws {
        let json = #"{"oauthAccount":{"emailAddress":"w@x.com","organizationName":"Acme","userRateLimitTier":"max_5x","organizationRateLimitTier":"default_claude_max_5x"}}"#
        try json.write(to: dir.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let account = AccountConfig(name: "work", configDir: dir.path)
        let id = try XCTUnwrap(claude.identity(account: account))
        XCTAssertEqual(id.email, "w@x.com")
        XCTAssertEqual(id.organization, "Acme")
        XCTAssertEqual(id.tier, "max_5x")
        XCTAssertEqual(id.organizationRateLimitTier, "default_claude_max_5x")
    }

    func testIdentityTierNilWhenAbsentOrMissing() throws {
        try #"{"oauthAccount":{"emailAddress":"a@b.com"}}"#
            .write(to: dir.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let account = AccountConfig(name: "work", configDir: dir.path)
        XCTAssertNil(claude.identity(account: account)?.organizationRateLimitTier)
        // No file at all -> nil.
        let empty = AccountConfig(name: "none", configDir: dir.appendingPathComponent("nope").path)
        XCTAssertNil(claude.identity(account: empty))
    }

    /// `claude auth login` leaves `{oauthAccount}` alone; the first `claude` there
    /// ran the onboarding wizard. Seeding marks it done and copies the theme, and
    /// touches nothing else; the default dir is never written.
    func testEnsureOnboardedStampsAFreshDirAndLeavesTheRestAlone() throws {
        let home = dir.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try #"{"hasCompletedOnboarding":true,"theme":"dark","numStartups":9}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let fresh = home.appendingPathComponent(".claude-accounts/fresh")
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        try #"{"oauthAccount":{"emailAddress":"f@x"}}"#
            .write(to: fresh.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        XCTAssertTrue(ClaudeService.ensureOnboarded(configDir: fresh.path, home: home.path))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fresh.appendingPathComponent(".claude.json"))) as? [String: Any])
        XCTAssertEqual(obj["hasCompletedOnboarding"] as? Bool, true)
        XCTAssertEqual(obj["theme"] as? String, "dark")
        XCTAssertEqual((obj["oauthAccount"] as? [String: Any])?["emailAddress"] as? String, "f@x", "the sign-in stays")
        XCTAssertNil(obj["numStartups"], "only the two keys, not the whole default config")
        XCTAssertFalse(ClaudeService.ensureOnboarded(configDir: fresh.path, home: home.path), "idempotent")
        XCTAssertFalse(ClaudeService.ensureOnboarded(configDir: home.path + "/.claude", home: home.path), "never the default dir")
    }

    /// A `.claude.json` caught mid-write (or broken by hand) doesn't parse. It used to be
    /// read as `{}` and replaced by the two onboarding keys, which signed the account out
    /// and dropped its MCP servers and project trust. Now it keeps every byte.
    func testEnsureOnboardedLeavesAClaudeJsonThatDoesNotParseAlone() throws {
        let home = dir.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try #"{"theme":"dark"}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let work = home.appendingPathComponent(".claude-accounts/work")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let file = work.appendingPathComponent(".claude.json")
        let truncated = Data((#"{"oauthAccount":{"emailAddress":"me@example.com","organizationUuid":"org-1"},"#
            + #""mcpServers":{"db":{"command":"db-mcp"}},"projects":{"/home/me/app":{"hasTrustDialogAccepted":true"#).utf8)
        try truncated.write(to: file)

        XCTAssertFalse(ClaudeService.ensureOnboarded(configDir: work.path, home: home.path))
        XCTAssertEqual(try Data(contentsOf: file), truncated)
    }

    /// A symlinked `.claude.json` stays a link: the stamp lands in its target, which keeps
    /// its mode, and `/` is not written as `\/`. Once onboarded it isn't written again.
    func testEnsureOnboardedWritesThroughASymlinkedClaudeJson() throws {
        let home = dir.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try #"{"theme":"dark"}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let target = dir.appendingPathComponent("dotfiles/claude.json")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"oauthAccount":{"emailAddress":"f@x"},"projects":{"/srv/app":{"hasTrustDialogAccepted":true}}}"#
            .write(to: target, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let work = home.appendingPathComponent(".claude-accounts/work")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let link = work.appendingPathComponent(".claude.json")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

        XCTAssertTrue(ClaudeService.ensureOnboarded(configDir: work.path, home: home.path))

        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), target.path)
        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertFalse(text.contains(#"\/"#), text)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(obj["hasCompletedOnboarding"] as? Bool, true)
        XCTAssertEqual(obj["theme"] as? String, "dark")
        XCTAssertEqual((obj["oauthAccount"] as? [String: Any])?["emailAddress"] as? String, "f@x")
        XCTAssertNotNil((obj["projects"] as? [String: Any])?["/srv/app"])
        XCTAssertEqual(try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int, 0o644)

        let before = try fm.attributesOfItem(atPath: target.path)
        XCTAssertFalse(ClaudeService.ensureOnboarded(configDir: work.path, home: home.path))
        let after = try fm.attributesOfItem(atPath: target.path)
        XCTAssertEqual(before[.systemFileNumber] as? Int, after[.systemFileNumber] as? Int)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }

    func testLaunchCommandCarriesTheBrowserRouter() {
        let account = AccountConfig(name: "w", configDir: "/tmp/w")
        let command = ClaudeService.launchCommand(account: account, browser: "/Applications/Brow.app/Contents/Resources/brow-browser")
        XCTAssertTrue(command.hasPrefix("CLAUDE_CONFIG_DIR='/tmp/w' BROWSER='/Applications/Brow.app/Contents/Resources/brow-browser' "), command)
        XCTAssertFalse(ClaudeService.launchCommand(account: account).contains("BROWSER="))
    }

    func testWithProcessValidatorTogglesLiveProcesses() throws {
        let sessions = dir.appendingPathComponent("sessions")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        try #"{"pid":4242,"sessionId":"s1","cwd":"/ws/a","status":"busy","startedAt":"2025-06-15T10:00:00Z"}"#
            .write(to: sessions.appendingPathComponent("4242.json"), atomically: true, encoding: .utf8)
        let account = AccountConfig(name: "work", configDir: dir.path)
        let live = claude.withProcessValidator { _ in true }.liveProcesses(account: account)
        XCTAssertEqual(live.map(\.sessionId), ["s1"])
        XCTAssertEqual(live.first?.status, "busy")
        XCTAssertNotNil(live.first?.startedAt)
        XCTAssertTrue(claude.withProcessValidator { _ in false }
            .liveProcesses(account: account).isEmpty)
    }

    func testLaunchCommandDefaultAccountHasNoEnvPrefixCustomAccountDoes() {
        let defaultAcc = AccountConfig(name: "default", configDir: "~/.claude")
        XCTAssertFalse(ClaudeService.launchCommand(account: defaultAcc).contains("CLAUDE_CONFIG_DIR"))
        let custom = AccountConfig(name: "work", configDir: "~/.claude-accounts/work")
        let cmd = ClaudeService.launchCommand(account: custom, resume: "id", model: "m", effort: "high")
        XCTAssertTrue(cmd.contains("CLAUDE_CONFIG_DIR="))
        XCTAssertTrue(cmd.contains("--resume 'id'"))
        XCTAssertTrue(cmd.contains("--model 'm'"))
        XCTAssertTrue(cmd.contains("--effort 'high'"))
    }
}

final class GroveErrorTests: XCTestCase {
    func testEveryCaseHasADescriptiveString() {
        XCTAssertTrue(GroveError.processFailed(command: "git x", exitCode: 2, stderr: "boom")
            .description.contains("exit 2"))
        XCTAssertTrue(GroveError.timeout(command: "slow").description.contains("timed out"))
        XCTAssertTrue(GroveError.invalidWorkspaceName("bad name")
            .description.contains("invalid workspace name"))
        XCTAssertTrue(GroveError.workspaceExists("/p").description.contains("already exists"))
        XCTAssertTrue(GroveError.cmuxUnavailable("down").description.contains("cmux unavailable"))
        XCTAssertTrue(GroveError.io("disk full").description.contains("I/O error"))
    }
}
