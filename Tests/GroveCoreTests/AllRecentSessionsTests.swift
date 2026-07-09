import XCTest
@testable import GroveCore

/// TDD tests for `ClaudeService.allRecentSessions(accounts:limit:sinceDays:now:)`.
/// These tests verify the disk-wide session scanner that has NO project/root filter.
final class AllRecentSessionsTests: XCTestCase {
    private let fm = FileManager.default
    private var configDir: URL!
    private let claude = ClaudeService()

    override func setUpWithError() throws {
        configDir = try Fixture.tempDir("all-recent-sessions")
    }

    private func account(_ name: String = "default", dir: URL? = nil) -> AccountConfig {
        AccountConfig(name: name, configDir: (dir ?? configDir).path)
    }

    /// Writes <configDir>/projects/<mangle(cwd)>/<id>.jsonl and sets its mtime.
    @discardableResult
    private func writeSession(in dir: URL? = nil,
                              cwd: String,
                              id: String,
                              title: String,
                              mtime: Date) throws -> URL {
        let base = (dir ?? configDir)
            .appendingPathComponent("projects")
            .appendingPathComponent(ClaudeService.mangle(cwd))
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","cwd":"\#(cwd)","sessionId":"\#(id)","gitBranch":"main"}"#,
            #"{"type":"ai-title","aiTitle":"\#(title)"}"#,
        ]
        let file = base.appendingPathComponent("\(id).jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        return file
    }

    // MARK: - Case 1: No root filter

    /// Sessions at arbitrary cwds NOT under any configured project must be returned.
    /// The old `recentSessions(underRoots:)` would drop these entirely.
    func testNoRootFilter_returnsSessionsAtAnyCwd() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = now.addingTimeInterval(-3600)   // 1h ago — within 7 days

        try writeSession(cwd: "/Users/x/Desktop/sigma", id: "s-desktop",
                         title: "Desktop work", mtime: recent)
        try writeSession(cwd: "/Users/x", id: "s-home",
                         title: "Home dir work", mtime: recent)

        let rows = claude.allRecentSessions(
            accounts: [account()], limit: 10, sinceDays: 7, now: now)
        let ids = rows.map(\.id)
        XCTAssertTrue(ids.contains("s-desktop"), "Desktop cwd must be included (no root filter)")
        XCTAssertTrue(ids.contains("s-home"),    "Home cwd must be included (no root filter)")
    }

    // MARK: - Case 2: Recency cap

    /// A transcript with mtime older than sinceDays*86400 before `now` is excluded;
    /// a recent one is included. The injected `now` drives the cutoff.
    func testRecencyCap_excludesOldTranscripts() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = now.addingTimeInterval(-7 * 86400)
        let justInside  = cutoff.addingTimeInterval(+60)    // 1 min inside the window
        let justOutside = cutoff.addingTimeInterval(-60)    // 1 min outside the window

        try writeSession(cwd: "/work/recent", id: "s-recent",
                         title: "Recent", mtime: justInside)
        try writeSession(cwd: "/work/old",    id: "s-old",
                         title: "Old",    mtime: justOutside)

        let rows = claude.allRecentSessions(
            accounts: [account()], limit: 10, sinceDays: 7, now: now)
        let ids = rows.map(\.id)
        XCTAssertTrue(ids.contains("s-recent"),   "Recent session must be included")
        XCTAssertFalse(ids.contains("s-old"),     "Old session must be excluded by recency cap")
    }

    // MARK: - Case 3: Newest-first ordering and limit

    /// Results must be sorted newest-first by mtime and capped at `limit`.
    func testNewestFirstAndLimit() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let base = now.addingTimeInterval(-3600)

        try writeSession(cwd: "/work/a", id: "s-a", title: "A", mtime: base)
        try writeSession(cwd: "/work/b", id: "s-b", title: "B",
                         mtime: base.addingTimeInterval(60))
        try writeSession(cwd: "/work/c", id: "s-c", title: "C",
                         mtime: base.addingTimeInterval(120))

        // limit=2: only two newest
        let rows = claude.allRecentSessions(
            accounts: [account()], limit: 2, sinceDays: 7, now: now)
        XCTAssertEqual(rows.map(\.id), ["s-c", "s-b"])
    }

    // MARK: - Case 4: Dedup by (cwd, sessionId)

    /// The same (cwd, id) pair present under two accounts collapses to one row (the newest).
    func testDedup_sameSessionAcrossTwoAccountsCollapsesToOne() throws {
        let secondDir = try Fixture.tempDir("all-recent-second")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cwd = "/work/shared-project"
        let id  = "dup-id-0001-4000-8000-000000000001"

        // Account 1: older copy
        try writeSession(in: configDir, cwd: cwd, id: id, title: "From account 1",
                         mtime: now.addingTimeInterval(-3600))
        // Account 2: newer copy (should be the one kept)
        try writeSession(in: secondDir, cwd: cwd, id: id, title: "From account 2",
                         mtime: now.addingTimeInterval(-1800))

        let rows = claude.allRecentSessions(
            accounts: [account("acct1"), account("acct2", dir: secondDir)],
            limit: 10, sinceDays: 7, now: now)
        let matching = rows.filter { $0.id == id }
        XCTAssertEqual(matching.count, 1,      "Same (cwd, id) must appear only once")
        XCTAssertEqual(matching.first?.accountName, "acct2",
                       "The newer instance (from acct2) must be kept")
    }

    // MARK: - Case 5: Multi-account

    /// Transcripts across two account configDirs are both returned.
    func testMultiAccount_bothAccountsScanned() throws {
        let secondDir = try Fixture.tempDir("all-recent-multi-acct")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = now.addingTimeInterval(-3600)

        try writeSession(in: configDir, cwd: "/work/proj-a", id: "s-acct1",
                         title: "Account 1 session", mtime: recent)
        try writeSession(in: secondDir, cwd: "/work/proj-b", id: "s-acct2",
                         title: "Account 2 session", mtime: recent)

        let rows = claude.allRecentSessions(
            accounts: [account("acct1"), account("acct2", dir: secondDir)],
            limit: 10, sinceDays: 7, now: now)
        let ids = Set(rows.map(\.id))
        XCTAssertTrue(ids.contains("s-acct1"), "Session from account 1 must be returned")
        XCTAssertTrue(ids.contains("s-acct2"), "Session from account 2 must be returned")
        XCTAssertEqual(rows.first { $0.id == "s-acct1" }?.accountName, "acct1")
        XCTAssertEqual(rows.first { $0.id == "s-acct2" }?.accountName, "acct2")
    }
}
