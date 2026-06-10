import XCTest
@testable import GroveCore

final class ClaudeServiceTests: XCTestCase {
    private var configDir: URL!
    private var account: AccountConfig!
    private var service: ClaudeService!

    override func setUpWithError() throws {
        configDir = try Fixture.tempDir("claude-config")
        account = AccountConfig(name: "work", configDir: configDir.path)
        service = ClaudeService()
    }

    // MARK: - Helpers

    private func makeProjectsDir(for cwd: String) throws -> URL {
        let dir = configDir
            .appendingPathComponent("projects")
            .appendingPathComponent(ClaudeService.mangle(cwd))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeJSONL(_ lines: [String], to dir: URL, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Realistic Claude Code transcript: metadata lines first, then a user record
    /// (sessionId/cwd/gitBranch/timestamp), an assistant reply, and optionally an ai-title record.
    private func transcriptLines(cwd: String, sessionId: String, branch: String,
                                 userText: String, aiTitle: String?) -> [String] {
        var lines = [
            #"{"type":"summary","summary":"Earlier exploration of the bug","leafUuid":"7f3c9d2e-1111-4222-8333-444455556666"}"#,
            #"{"type":"file-history-snapshot","messageId":"msg-001","snapshot":{"trackedFiles":[]},"isSnapshotUpdate":false}"#,
            #"{"parentUuid":null,"isSidechain":false,"userType":"external","cwd":"\#(cwd)","sessionId":"\#(sessionId)","version":"2.0.14","gitBranch":"\#(branch)","type":"user","message":{"role":"user","content":"\#(userText)"},"uuid":"\#(sessionId)-u1","timestamp":"2026-06-10T10:00:00.000Z"}"#,
            #"{"parentUuid":"\#(sessionId)-u1","isSidechain":false,"userType":"external","cwd":"\#(cwd)","sessionId":"\#(sessionId)","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking at it now."}]},"uuid":"\#(sessionId)-a1","timestamp":"2026-06-10T10:00:05.000Z"}"#,
        ]
        if let aiTitle {
            lines.append(#"{"type":"ai-title","aiTitle":"\#(aiTitle)","sessionId":"\#(sessionId)","timestamp":"2026-06-10T10:01:00.000Z"}"#)
        }
        return lines
    }

    // MARK: - mangle

    func testMangleExampleFromContract() {
        XCTAssertEqual(ClaudeService.mangle("/a/b.c"), "-a-b-c")
    }

    func testMangleReplacesUnderscoreDotSlashAndUnicode() {
        // underscore, dot, slash all become "-"
        XCTAssertEqual(ClaudeService.mangle("/Users/dev/my_app.v2"), "-Users-dev-my-app-v2")
        // unicode (non-ASCII) chars each become "-": "папка" = 5 scalars -> 5 dashes
        XCTAssertEqual(ClaudeService.mangle("/tmp/папка"), "-tmp------")
        // ASCII letters and digits pass through unchanged
        XCTAssertEqual(ClaudeService.mangle("/Users/A1/B2"), "-Users-A1-B2")
    }

    func testMangleIsLossy() {
        // This collision is exactly why sessions() must verify the cwd field inside the jsonl.
        XCTAssertEqual(ClaudeService.mangle("/work/demo_app"), ClaudeService.mangle("/work/demo-app"))
    }

    // MARK: - identity

    func testIdentityReadsOAuthAccountFromConfigDir() throws {
        let json = """
        {
          "numStartups": 17,
          "installMethod": "native",
          "oauthAccount": {
            "accountUuid": "f0e1d2c3-b4a5-4697-8809-aabbccddeeff",
            "emailAddress": "work@example.com",
            "organizationName": "Acme Corp",
            "organizationUuid": "11223344-5566-4788-99aa-bbccddeeff00",
            "userRateLimitTier": "max_20x"
          }
        }
        """
        try json.write(to: configDir.appendingPathComponent(".claude.json"),
                       atomically: true, encoding: .utf8)

        let identity = try XCTUnwrap(service.identity(account: account))
        XCTAssertEqual(identity.email, "work@example.com")
        XCTAssertEqual(identity.organization, "Acme Corp")
        XCTAssertEqual(identity.tier, "max_20x")
    }

    func testIdentityNilWhenConfigJsonMissing() {
        XCTAssertNil(service.identity(account: account))
    }

    // MARK: - sessions

    func testSessionsReadsMatchingTranscriptWithAiTitle() throws {
        let cwd = "/work/demo_app"
        let dir = try makeProjectsDir(for: cwd)
        let id = "0a1b2c3d-0001-4000-8000-000000000001"
        try writeJSONL(
            transcriptLines(cwd: cwd, sessionId: id, branch: "feat/media-pipeline",
                            userText: "Fix the flaky media upload retries",
                            aiTitle: "Flaky media upload retries"),
            to: dir, name: "\(id).jsonl")

        let sessions = service.sessions(for: cwd, account: account)
        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.cwd, cwd)
        XCTAssertEqual(session.title, "Flaky media upload retries")
        XCTAssertEqual(session.gitBranch, "feat/media-pipeline")
        XCTAssertEqual(session.accountName, "work")
    }

    func testSessionsFiltersFileWhoseCwdMismatches() throws {
        let cwd = "/work/demo_app"
        // "/work/demo-app" mangles to the SAME directory name -> lands in the same projects dir.
        let dir = try makeProjectsDir(for: cwd)
        let goodId = "0a1b2c3d-0002-4000-8000-000000000002"
        let imposterId = "0a1b2c3d-0003-4000-8000-000000000003"
        try writeJSONL(
            transcriptLines(cwd: cwd, sessionId: goodId, branch: "feat/good",
                            userText: "Work in the right checkout", aiTitle: "Right checkout work"),
            to: dir, name: "\(goodId).jsonl")
        try writeJSONL(
            transcriptLines(cwd: "/work/demo-app", sessionId: imposterId, branch: "feat/imposter",
                            userText: "Work in a different checkout", aiTitle: "Imposter"),
            to: dir, name: "\(imposterId).jsonl")

        let sessions = service.sessions(for: cwd, account: account)
        XCTAssertEqual(sessions.map(\.id), [goodId])
    }

    func testSessionsIgnoresJsonlInsideSubdirectories() throws {
        let cwd = "/work/demo_app"
        let dir = try makeProjectsDir(for: cwd)
        let nested = dir.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedId = "0a1b2c3d-0004-4000-8000-000000000004"
        try writeJSONL(
            transcriptLines(cwd: cwd, sessionId: nestedId, branch: "feat/archived",
                            userText: "Archived conversation", aiTitle: "Archived"),
            to: nested, name: "\(nestedId).jsonl")

        XCTAssertEqual(service.sessions(for: cwd, account: account), [])
    }

    func testSessionsTitleFallsBackToFirstExternalUserMessagePrefix80() throws {
        let cwd = "/work/demo_app"
        let dir = try makeProjectsDir(for: cwd)
        let id = "0a1b2c3d-0005-4000-8000-000000000005"
        let longMessage = String(repeating: "abcdefghij", count: 10) // 100 chars
        let lines = [
            #"{"type":"summary","summary":"Old context","leafUuid":"7f3c9d2e-2222-4222-8333-444455556666"}"#,
            // Internal user record (tool result, no "userType":"external") comes FIRST:
            // it supplies sessionId/gitBranch but must NOT supply the fallback title.
            #"{"parentUuid":null,"isSidechain":false,"cwd":"/work/demo_app","sessionId":"\#(id)","gitBranch":"feat/long","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"ok"}]},"uuid":"\#(id)-u0","timestamp":"2026-06-10T11:00:00.000Z"}"#,
            #"{"parentUuid":"\#(id)-u0","isSidechain":false,"userType":"external","cwd":"/work/demo_app","sessionId":"\#(id)","gitBranch":"feat/long","type":"user","message":{"role":"user","content":"\#(longMessage)"},"uuid":"\#(id)-u1","timestamp":"2026-06-10T11:00:10.000Z"}"#,
        ]
        try writeJSONL(lines, to: dir, name: "\(id).jsonl")

        let session = try XCTUnwrap(service.sessions(for: cwd, account: account).first)
        XCTAssertEqual(session.title, String(repeating: "abcdefghij", count: 8)) // first 80 chars
        XCTAssertEqual(session.title?.count, 80)
        XCTAssertEqual(session.gitBranch, "feat/long")
    }

    func testSessionsSortedNewestFirstByMtime() throws {
        let cwd = "/work/demo_app"
        let dir = try makeProjectsDir(for: cwd)
        let oldId = "0a1b2c3d-0006-4000-8000-000000000006"
        let newId = "0a1b2c3d-0007-4000-8000-000000000007"
        let oldURL = try writeJSONL(
            transcriptLines(cwd: cwd, sessionId: oldId, branch: "feat/old",
                            userText: "old work", aiTitle: "Old"),
            to: dir, name: "\(oldId).jsonl")
        let newURL = try writeJSONL(
            transcriptLines(cwd: cwd, sessionId: newId, branch: "feat/new",
                            userText: "new work", aiTitle: "New"),
            to: dir, name: "\(newId).jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: oldURL.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: newURL.path)

        XCTAssertEqual(service.sessions(for: cwd, account: account).map(\.id), [newId, oldId])
    }
}
