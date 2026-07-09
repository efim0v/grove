import XCTest
import GroveCore
@testable import GroveAppKit

/// Tests for buildExternalSessionRows — the dedup/presentation function that
/// filters out already-shown (cwd, sessionId) pairs and converts ClaudeSession
/// → ExternalSessionRow grouped by cwd.
final class ExternalSessionRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    // MARK: - Fixture helpers

    private func snapshotRow(cwd: String, sessionId: String) -> SessionRow {
        SessionRow(sessionId: sessionId,
                   title: sessionId,
                   location: (cwd as NSString).lastPathComponent,
                   accountName: "default",
                   accounts: ["default"],
                   cwd: cwd,
                   liveStatus: nil,
                   startedAt: nil,
                   lastActivity: now,
                   action: .resume,
                   cmuxWorkspaceId: nil)
    }

    private func externalSession(_ id: String, cwd: String,
                                 account: String = "default",
                                 age: TimeInterval = 0) -> ClaudeSession {
        ClaudeSession(id: id, cwd: cwd, title: "T-\(id)",
                      lastActivity: ago(age),
                      accountName: account, gitBranch: nil)
    }

    // MARK: - Dedup: already-shown (cwd, sessionId) is excluded

    func testAlreadyShownSessionIsExcluded() {
        let snapshotRows = [snapshotRow(cwd: "/ws/x", sessionId: "idA")]
        let external = [
            externalSession("idA", cwd: "/ws/x"),   // duplicate — same (cwd, id)
            externalSession("idB", cwd: "/ws/y"),   // new
        ]
        let result = buildExternalSessionRows(snapshotRows: snapshotRows,
                                              externalSessions: external)
        XCTAssertEqual(result.map(\.sessionId), ["idB"],
                       "The (cwd, sessionId) already in snapshot rows must be excluded")
    }

    func testSessionWithSameIdButDifferentCwdIsNotExcluded() {
        // Same sessionId, different cwd → different (cwd, sessionId) key → keep it.
        let snapshotRows = [snapshotRow(cwd: "/ws/x", sessionId: "idA")]
        let external = [externalSession("idA", cwd: "/ws/different")]
        let result = buildExternalSessionRows(snapshotRows: snapshotRows,
                                              externalSessions: external)
        XCTAssertEqual(result.map(\.sessionId), ["idA"],
                       "Same sessionId at a DIFFERENT cwd is NOT a duplicate")
    }

    func testNoDuplicatesWhenSnapshotRowsEmpty() {
        let external = [
            externalSession("idA", cwd: "/ws/x"),
            externalSession("idB", cwd: "/ws/y"),
        ]
        let result = buildExternalSessionRows(snapshotRows: [],
                                              externalSessions: external)
        XCTAssertEqual(Set(result.map(\.sessionId)), ["idA", "idB"],
                       "No snapshot rows → all external sessions pass through")
    }

    func testEmptyExternalSessionsReturnsEmpty() {
        let snapshotRows = [snapshotRow(cwd: "/ws/x", sessionId: "idA")]
        let result = buildExternalSessionRows(snapshotRows: snapshotRows,
                                              externalSessions: [])
        XCTAssertTrue(result.isEmpty, "Empty external sessions → empty result")
    }

    func testBothEmptyReturnsEmpty() {
        let result = buildExternalSessionRows(snapshotRows: [], externalSessions: [])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Grouping by cwd

    func testRowsGroupedByCwdAndLocationIsLeaf() {
        let external = [
            externalSession("id1", cwd: "/p/alpha/work"),
            externalSession("id2", cwd: "/p/alpha/work"),   // same cwd as id1
            externalSession("id3", cwd: "/p/beta/feat"),    // different cwd
        ]
        let result = buildExternalSessionRows(snapshotRows: [], externalSessions: external)
        XCTAssertEqual(result.count, 3)
        let cwdSet = Set(result.map(\.cwd))
        XCTAssertEqual(cwdSet, ["/p/alpha/work", "/p/beta/feat"])
        // Location label is the leaf directory name of cwd.
        let locations = Set(result.map(\.location))
        XCTAssertEqual(locations, ["work", "feat"],
                       "Location must be the leaf directory of the session's cwd")
    }

    // MARK: - Account propagation

    func testAccountNamePropagatesFromClaudeSession() {
        let external = [externalSession("id1", cwd: "/ws/x", account: "work")]
        let result = buildExternalSessionRows(snapshotRows: [], externalSessions: external)
        XCTAssertEqual(result.first?.accountName, "work")
    }

    // MARK: - Resume action + cwd available for T4

    func testExternalRowsHaveResumeAction() {
        let external = [externalSession("id1", cwd: "/ws/x")]
        let result = buildExternalSessionRows(snapshotRows: [], externalSessions: external)
        XCTAssertEqual(result.first?.action, .resume,
                       "External sessions are always resumable (not live)")
    }

    func testCwdAvailableOnRow() {
        let external = [externalSession("id1", cwd: "/p/project/sub")]
        let result = buildExternalSessionRows(snapshotRows: [], externalSessions: external)
        XCTAssertEqual(result.first?.cwd, "/p/project/sub",
                       "cwd must be available on the row for T4 Share affordance")
    }

    // MARK: - Multiple dupes in snapshotRows all excluded

    func testMultipleDuplicatesAllExcluded() {
        let snapshotRows = [
            snapshotRow(cwd: "/ws/a", sessionId: "s1"),
            snapshotRow(cwd: "/ws/b", sessionId: "s2"),
        ]
        let external = [
            externalSession("s1", cwd: "/ws/a"),   // dup
            externalSession("s2", cwd: "/ws/b"),   // dup
            externalSession("s3", cwd: "/ws/c"),   // new
        ]
        let result = buildExternalSessionRows(snapshotRows: snapshotRows,
                                              externalSessions: external)
        XCTAssertEqual(result.map(\.sessionId), ["s3"])
    }
}

/// Tests for buildOtherSessionRows — ClaudeSession[] → SessionRow[] grouped by cwd,
/// newest-first preserved.
final class OtherSessionRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    private func session(_ id: String, cwd: String,
                         account: String = "default",
                         age: TimeInterval = 0) -> ClaudeSession {
        ClaudeSession(id: id, cwd: cwd, title: "T-\(id)",
                      lastActivity: ago(age),
                      accountName: account, gitBranch: nil)
    }

    func testEmptyInputReturnsEmpty() {
        let result = buildOtherSessionRows(sessions: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testLocationIsLeafDirOfCwd() {
        let result = buildOtherSessionRows(sessions: [session("s1", cwd: "/x/y/leaf")])
        XCTAssertEqual(result.first?.location, "leaf")
    }

    func testAccountNamePropagates() {
        let result = buildOtherSessionRows(sessions: [session("s1", cwd: "/x", account: "work")])
        XCTAssertEqual(result.first?.accountName, "work")
    }

    func testAllRowsHaveResumeAction() {
        let result = buildOtherSessionRows(sessions: [
            session("s1", cwd: "/x"),
            session("s2", cwd: "/y"),
        ])
        XCTAssertTrue(result.allSatisfy { $0.action == .resume })
    }

    func testNewestFirstOrderPreserved() {
        // Sessions passed in oldest-first; output must preserve the order from the
        // caller (which is newest-first from allRecentSessions). If input is already
        // newest-first the order must not be changed.
        let input = [
            session("s1", cwd: "/x", age: 0),      // newest
            session("s2", cwd: "/y", age: 3600),   // older
            session("s3", cwd: "/z", age: 7200),   // oldest
        ]
        let result = buildOtherSessionRows(sessions: input)
        XCTAssertEqual(result.map(\.sessionId), ["s1", "s2", "s3"],
                       "Input order (newest-first from caller) must be preserved")
    }

    func testCwdAvailableOnRow() {
        let result = buildOtherSessionRows(sessions: [session("s1", cwd: "/p/q/r")])
        XCTAssertEqual(result.first?.cwd, "/p/q/r")
    }

    func testMultipleSessionsProduceMultipleRows() {
        let result = buildOtherSessionRows(sessions: [
            session("a", cwd: "/ws/a"),
            session("b", cwd: "/ws/b"),
            session("c", cwd: "/ws/a"),   // same cwd as "a" — different session
        ])
        XCTAssertEqual(result.count, 3)
    }
}
