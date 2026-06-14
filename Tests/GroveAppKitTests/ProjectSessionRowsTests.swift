import XCTest
@testable import GroveAppKit
import GroveCore

final class ProjectSessionRowsTests: XCTestCase {
    private func session(_ id: String, cwd: String = "/ws/a", title: String? = "T",
                         account: String = "default") -> ClaudeSession {
        ClaudeSession(id: id, cwd: cwd, title: title, lastActivity: Date(),
                      accountName: account, gitBranch: nil)
    }

    private func live(_ sessionId: String, status: String) -> LiveProcess {
        LiveProcess(pid: 1, sessionId: sessionId, cwd: "/ws/a", status: status, accountName: "default")
    }

    func testClosedWhenNoLiveProcess() {
        let rows = buildProjectSessionRows(sessions: [session("s1")], live: [], cmuxMap: [:])
        XCTAssertEqual(rows.first?.status, .closed)
        XCTAssertNil(rows.first?.cmuxWorkspaceId)
        XCTAssertFalse(rows.first?.canGo ?? true)
    }

    func testRunningAndWaitingFromLiveStatus() {
        let rows = buildProjectSessionRows(
            sessions: [session("busy"), session("wait"), session("idle"), session("shell")],
            live: [live("busy", status: "busy"),
                   live("wait", status: "waiting"),
                   live("idle", status: "idle"),
                   live("shell", status: "shell")],
            cmuxMap: [:])
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionId, $0.status) })
        // Only "busy" is genuinely running; "idle"/"shell" mean the session finished
        // its turn and is waiting for the next prompt (the actionable state).
        XCTAssertEqual(byId["busy"], .running)
        XCTAssertEqual(byId["wait"], .waiting)
        XCTAssertEqual(byId["idle"], .waiting)
        XCTAssertEqual(byId["shell"], .waiting)
    }

    func testFreshSessionMatchedByCwdWhenSessionIdMissing() {
        // A fresh (no --resume) live process carries cwd, empty sessionId. A recent
        // session at that directory must read LIVE (running), not closed.
        let rows = buildProjectSessionRows(
            sessions: [session("fresh-1", cwd: "/ws/group-chats/")],
            live: [LiveProcess(pid: 9, sessionId: "", cwd: "/ws/group-chats", status: "busy", accountName: "")],
            cmuxMap: [:])
        XCTAssertEqual(rows.first?.status, .running)   // not .closed
    }

    func testSessionIdMatchWinsOverCwdMatch() {
        let rows = buildProjectSessionRows(
            sessions: [session("s1", cwd: "/ws/a")],
            live: [LiveProcess(pid: 1, sessionId: "s1", cwd: "", status: "idle", accountName: ""),
                   LiveProcess(pid: 2, sessionId: "", cwd: "/ws/a", status: "busy", accountName: "")],
            cmuxMap: [:])
        XCTAssertEqual(rows.first?.status, .waiting)    // the id-matched "idle" wins
    }

    func testGoTargetFromCmuxMap() {
        let rows = buildProjectSessionRows(sessions: [session("s1")],
                                           live: [live("s1", status: "busy")],
                                           cmuxMap: ["s1": "ws-3"])
        XCTAssertEqual(rows.first?.cmuxWorkspaceId, "ws-3")
        XCTAssertTrue(rows.first?.canGo ?? false)
    }

    func testTitleFallsBackToSessionIdPrefixAndLocationIsLeaf() {
        let rows = buildProjectSessionRows(sessions: [session("abcdefgh12345", cwd: "/p/work", title: nil)],
                                           live: [], cmuxMap: [:])
        XCTAssertEqual(rows.first?.title, "abcdefgh")
        XCTAssertEqual(rows.first?.location, "work")
    }
}
