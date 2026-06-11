import XCTest
import GroveCore
@testable import GroveAppKit

final class SessionRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    // MARK: - fixture builders

    private func session(_ id: String, account: String = "default",
                         title: String? = nil, cwd: String = "/ws/feature",
                         age: TimeInterval = 0) -> ClaudeSession {
        ClaudeSession(id: id, cwd: cwd, title: title, lastActivity: ago(age),
                      accountName: account, gitBranch: nil)
    }

    private func live(_ pid: Int32, session: String, status: String,
                      account: String = "default", cwd: String = "/ws/feature",
                      startedAt: Date? = nil) -> LiveProcess {
        LiveProcess(pid: pid, sessionId: session, cwd: cwd, status: status,
                    accountName: account, startedAt: startedAt)
    }

    private func workspace(_ name: String, umbrella: String? = nil,
                           sessions: [ClaudeSession], live: [LiveProcess] = [],
                           cmux: [CmuxWorkspace] = []) -> FeatureWorkspace {
        FeatureWorkspace(name: name, umbrellaPath: umbrella ?? "/ws/\(name)", repos: [],
                         parentName: nil, sessions: sessions, liveProcesses: live,
                         cmuxWorkspaces: cmux)
    }

    private func loose(_ leaf: String, path: String? = nil,
                       sessions: [ClaudeSession], live: [LiveProcess] = [],
                       cmux: [CmuxWorkspace] = []) -> LooseWorktree {
        let p = path ?? "/p/client/.worktrees/\(leaf)"
        return LooseWorktree(
            repo: RepoInfo(path: "/p/client", dirName: "client"),
            entry: WorktreeEntry(path: p, branch: leaf, head: "abc", isMain: false),
            meta: nil, sessions: sessions, liveProcesses: live, cmuxWorkspaces: cmux)
    }

    private func snapshot(workspaces: [FeatureWorkspace] = [],
                         loose: [LooseWorktree] = []) -> ProjectSnapshot {
        ProjectSnapshot(project: ProjectConfig(name: "demo", path: "/p"),
                        repos: [], workspaces: workspaces, loose: loose, errors: [])
    }

    // MARK: - live + mapped -> Go

    func testLiveSessionMappedInCmuxMapGetsGoAction() {
        let snap = snapshot(workspaces: [
            workspace("media-pipeline",
                      sessions: [session("s1", title: "Pipeline fix")],
                      live: [live(42, session: "s1", status: "busy",
                                  startedAt: ago(300))]),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: ["s1": "cmux-ws-1"], now: now)
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.id, "s1")
        XCTAssertEqual(row.action, .go)
        XCTAssertEqual(row.liveStatus, .busy)
        XCTAssertEqual(row.startedAt, ago(300))
        XCTAssertEqual(row.title, "Pipeline fix")
        XCTAssertEqual(row.location, "media-pipeline")
        XCTAssertEqual(row.accountName, "default")
    }

    func testLiveSessionWhoseCwdIsListedByACmuxWorkspaceGetsGoEvenWhenUnmapped() {
        let cwd = "/ws/media-upload"
        let snap = snapshot(workspaces: [
            workspace("media-upload", umbrella: cwd,
                      sessions: [session("s2", cwd: cwd)],
                      live: [live(7, session: "s2", status: "waiting", cwd: cwd)],
                      cmux: [CmuxWorkspace(id: "cw", title: "media", currentDirectory: cwd)]),
        ])
        // empty cmux hook map — the cmux-workspace-lists-cwd path must still yield Go.
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:], now: now)
        XCTAssertEqual(rows.map(\.action), [.go])
        XCTAssertEqual(rows[0].liveStatus, .waiting)
    }

    // MARK: - live + unmapped -> Resume

    func testLiveSessionNotMappedAndNoCmuxCwdGetsResume() {
        let snap = snapshot(workspaces: [
            workspace("orphan",
                      sessions: [session("s3")],
                      live: [live(9, session: "s3", status: "idle")]),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:], now: now)
        XCTAssertEqual(rows.map(\.action), [.resume])
        XCTAssertEqual(rows[0].liveStatus, .idle)
    }

    // MARK: - resumable (not live)

    func testNonLiveSessionIsResumableWithNilStatus() {
        let snap = snapshot(workspaces: [
            workspace("old", sessions: [session("s4", age: 7200)], live: []),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: ["s4": "anything"], now: now)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].liveStatus, "a session with no live process is resumable")
        XCTAssertEqual(rows[0].action, .resume)
        XCTAssertEqual(rows[0].lastActivity, ago(7200))
    }

    // MARK: - title fallback

    func testTitleFallsBackToIdPrefix8() {
        let snap = snapshot(workspaces: [
            workspace("w", sessions: [session("0a1b2c3d-dead-beef", title: nil)]),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:], now: now)
        XCTAssertEqual(rows[0].title, "0a1b2c3d")
    }

    // MARK: - location derivation

    func testLooseSessionLocationIsWorktreeLeaf() {
        let snap = snapshot(loose: [
            loose("group-chats", path: "/p/client/.worktrees/group-chats",
                  sessions: [session("s5", cwd: "/p/client/.worktrees/group-chats")]),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:], now: now)
        XCTAssertEqual(rows.map(\.location), ["group-chats"])
    }

    // MARK: - account propagation

    func testAccountNamePropagatesFromSession() {
        let snap = snapshot(workspaces: [
            workspace("w", sessions: [session("s6", account: "work")]),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:], now: now)
        XCTAssertEqual(rows.map(\.accountName), ["work"])
    }

    // MARK: - sorting

    func testSortLiveFirstByStatusThenResumableByActivityDesc() {
        // Two accounts, mixed live statuses + resumables out of order.
        let snap = snapshot(workspaces: [
            workspace("a",
                      sessions: [session("idle1"), session("busy1"),
                                 session("wait1"), session("res-old", age: 9000),
                                 session("res-new", age: 100)],
                      live: [live(1, session: "idle1", status: "idle"),
                             live(2, session: "busy1", status: "busy"),
                             live(3, session: "wait1", status: "waiting")]),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:], now: now)
        // live first: busy, waiting, idle — then resumable newest-first.
        XCTAssertEqual(rows.map(\.id), ["busy1", "wait1", "idle1", "res-new", "res-old"])
    }

    func testAggregatesWorkspacesAndLooseTogether() {
        let snap = snapshot(
            workspaces: [workspace("w", sessions: [session("a")])],
            loose: [loose("leaf", sessions: [session("b")])])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:], now: now)
        XCTAssertEqual(Set(rows.map(\.id)), ["a", "b"])
    }

    // MARK: - shell status is not a recognised live status (renders as idle-ish)

    func testUnknownStatusTreatedAsIdleBucket() {
        let snap = snapshot(workspaces: [
            workspace("w", sessions: [session("sh")],
                      live: [live(5, session: "sh", status: "shell")]),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:], now: now)
        // unknown/shell status is still "live" but sorts in the idle bucket.
        XCTAssertEqual(rows[0].liveStatus, .idle)
    }
}
