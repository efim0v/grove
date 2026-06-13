import XCTest
@testable import GroveCore

final class RecentSessionsTests: XCTestCase {
    private let fm = FileManager.default
    private var configDir: URL!
    private let claude = ClaudeService()

    override func setUpWithError() throws {
        configDir = try Fixture.tempDir("recent-sessions")
    }

    private func account(_ name: String = "default", dir: URL? = nil) -> AccountConfig {
        AccountConfig(name: name, configDir: (dir ?? configDir).path)
    }

    /// Writes <configDir>/projects/<mangle(cwd)>/<id>.jsonl with a real cwd +
    /// sessionId + ai-title, and back-dates its mtime by `ageSeconds`.
    private func writeSession(in dir: URL? = nil, cwd: String, id: String,
                              title: String, ageSeconds: TimeInterval) throws {
        let base = (dir ?? configDir).appendingPathComponent("projects")
            .appendingPathComponent(ClaudeService.mangle(cwd))
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","cwd":"\#(cwd)","sessionId":"\#(id)","gitBranch":"main"}"#,
            #"{"type":"ai-title","aiTitle":"\#(title)"}"#,
        ]
        let file = base.appendingPathComponent("\(id).jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-ageSeconds)],
                             ofItemAtPath: file.path)
    }

    func testReturnsNewestUnderRootCappedAtLimit() throws {
        let root = "/Users/x/Projects/grove"
        try writeSession(cwd: root + "/.worktrees/a", id: "s-old", title: "Old", ageSeconds: 300)
        try writeSession(cwd: root + "/.worktrees/b", id: "s-new", title: "New", ageSeconds: 10)
        try writeSession(cwd: root, id: "s-mid", title: "Mid", ageSeconds: 100)

        let rows = claude.recentSessions(underRoots: [root], accounts: [account()], limit: 2)
        XCTAssertEqual(rows.map(\.id), ["s-new", "s-mid"])   // newest two under root
        XCTAssertEqual(rows.first?.title, "New")
        XCTAssertEqual(rows.first?.accountName, "default")
    }

    func testExcludesSessionsUnderOtherProjects() throws {
        let root = "/Users/x/Projects/grove"
        try writeSession(cwd: root + "/a", id: "mine", title: "Mine", ageSeconds: 50)
        try writeSession(cwd: "/Users/x/Other/zzz", id: "theirs", title: "Theirs", ageSeconds: 1)
        let rows = claude.recentSessions(underRoots: [root], accounts: [account()], limit: 5)
        XCTAssertEqual(rows.map(\.id), ["mine"])
    }

    /// A cwd that only SHARES the mangled prefix ("/a/bc" vs root "/a/b") passes
    /// the cheap prefilter but is rejected by the real-cwd check.
    func testRejectsMangledPrefixFalsePositive() throws {
        let root = "/a/b"
        try writeSession(cwd: "/a/bc", id: "sibling", title: "Sibling", ageSeconds: 1)
        try writeSession(cwd: "/a/b/inside", id: "inside", title: "Inside", ageSeconds: 2)
        let rows = claude.recentSessions(underRoots: [root], accounts: [account()], limit: 5)
        XCTAssertEqual(rows.map(\.id), ["inside"])
    }

    func testMergesAcrossAccountsByRecency() throws {
        let other = try Fixture.tempDir("recent-other")
        let root = "/Users/x/Projects/grove"
        try writeSession(cwd: root + "/a", id: "def", title: "FromDefault", ageSeconds: 200)
        try writeSession(in: other, cwd: root + "/b", id: "wrk", title: "FromWork", ageSeconds: 5)
        let rows = claude.recentSessions(
            underRoots: [root],
            accounts: [account(), account("work", dir: other)], limit: 5)
        XCTAssertEqual(rows.map(\.id), ["wrk", "def"])            // newest across accounts first
        XCTAssertEqual(rows.first?.accountName, "work")
    }

    /// The Projects-tab data path must stay well under the 0.5s UI budget even
    /// with a large transcript corpus — the indexer parses only a bounded buffer
    /// of the newest candidates, never the whole set.
    func testStaysFastWithManyTranscriptFiles() throws {
        let root = "/Users/x/Projects/big"
        for i in 0..<80 {
            try writeSession(cwd: root + "/ws-\(i)", id: "s-\(i)", title: "S\(i)",
                             ageSeconds: Double(i))
        }
        let start = Date()
        let rows = claude.recentSessions(underRoots: [root], accounts: [account()], limit: 2)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(rows.map(\.id), ["s-0", "s-1"])   // the two newest (smallest age)
        XCTAssertLessThan(elapsed, 0.5, "recent-session index must stay under the 0.5s UI budget")
    }

    func testEmptyForNoRootsOrZeroLimit() {
        XCTAssertTrue(claude.recentSessions(underRoots: [], accounts: [account()], limit: 5).isEmpty)
        XCTAssertTrue(claude.recentSessions(underRoots: ["/x"], accounts: [account()], limit: 0).isEmpty)
    }
}
