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
