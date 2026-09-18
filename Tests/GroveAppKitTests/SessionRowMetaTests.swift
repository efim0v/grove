import XCTest
@testable import GroveAppKit
import GroveCore

/// The Claude-tab redesign replaced the fixed-width columns (which truncated the
/// title and location) with a multi-line card. The invariant now is that the
/// extra meta a card renders — git branch, created-at, turn count, model — is
/// carried from `ClaudeSession` all the way onto the `SessionRow`, and degrades
/// to safe defaults for older transcripts that lack it.
final class SessionRowMetaTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_700_000_000)

    func testExternalRowCarriesSessionMeta() {
        let session = ClaudeSession(
            id: "s1", cwd: "/ws/feat", title: "Task",
            lastActivity: created.addingTimeInterval(3600),
            accountName: "default", gitBranch: "feat/x",
            createdAt: created, turnCount: 7, model: "claude-opus-4-8")
        let rows = buildExternalSessionRows(snapshotRows: [], externalSessions: [session])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.gitBranch, "feat/x")
        XCTAssertEqual(rows.first?.createdAt, created)
        XCTAssertEqual(rows.first?.turnCount, 7)
        XCTAssertEqual(rows.first?.model, "claude-opus-4-8")
    }

    func testOtherRowCarriesSessionMeta() {
        let session = ClaudeSession(
            id: "s2", cwd: "/loose/y", title: "Other",
            lastActivity: created.addingTimeInterval(60),
            accountName: "work", gitBranch: "dev",
            createdAt: created, turnCount: 1, model: "claude-sonnet-5")
        let rows = buildOtherSessionRows(sessions: [session])
        XCTAssertEqual(rows.first?.gitBranch, "dev")
        XCTAssertEqual(rows.first?.turnCount, 1)
        XCTAssertEqual(rows.first?.model, "claude-sonnet-5")
        XCTAssertEqual(rows.first?.createdAt, created)
    }

    /// Older transcripts parsed before the meta existed → nil/0 defaults, no crash.
    func testDefaultsWhenMetaAbsent() {
        let session = ClaudeSession(id: "s3", cwd: "/ws/z", title: "Z",
                                    lastActivity: Date(), accountName: "default", gitBranch: nil)
        let rows = buildOtherSessionRows(sessions: [session])
        XCTAssertNil(rows.first?.gitBranch)
        XCTAssertNil(rows.first?.createdAt)
        XCTAssertEqual(rows.first?.turnCount, 0)
        XCTAssertNil(rows.first?.model)
    }
}
