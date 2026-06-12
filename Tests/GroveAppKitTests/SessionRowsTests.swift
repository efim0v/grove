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
        let rows = buildSessionRows(snapshot: snap, cmuxMap: ["s1": "cmux-ws-1"])
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.sessionId, "s1")
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
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:])
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
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:])
        XCTAssertEqual(rows.map(\.action), [.resume])
        XCTAssertEqual(rows[0].liveStatus, .idle)
    }

    // MARK: - resumable (not live)

    func testNonLiveSessionIsResumableWithNilStatus() {
        let snap = snapshot(workspaces: [
            workspace("old", sessions: [session("s4", age: 7200)], live: []),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: ["s4": "anything"])
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
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:])
        XCTAssertEqual(rows[0].title, "0a1b2c3d")
    }

    // MARK: - location derivation

    func testLooseSessionLocationIsWorktreeLeaf() {
        let snap = snapshot(loose: [
            loose("group-chats", path: "/p/client/.worktrees/group-chats",
                  sessions: [session("s5", cwd: "/p/client/.worktrees/group-chats")]),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:])
        XCTAssertEqual(rows.map(\.location), ["group-chats"])
    }

    // MARK: - account propagation

    func testAccountNamePropagatesFromSession() {
        let snap = snapshot(workspaces: [
            workspace("w", sessions: [session("s6", account: "work")]),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:])
        XCTAssertEqual(rows.map(\.accountName), ["work"])
        XCTAssertEqual(rows.map(\.accounts), [["work"]])
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
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:])
        // live first: busy, waiting, idle — then resumable newest-first.
        XCTAssertEqual(rows.map(\.sessionId), ["busy1", "wait1", "idle1", "res-new", "res-old"])
    }

    func testAggregatesWorkspacesAndLooseTogether() {
        let snap = snapshot(
            workspaces: [workspace("w", sessions: [session("a")])],
            loose: [loose("leaf", sessions: [session("b")])])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:])
        XCTAssertEqual(Set(rows.map(\.sessionId)), ["a", "b"])
    }

    // MARK: - cross-account collapse (shared store)

    /// With a shared store the SAME sessionId at one cwd is listed under every
    /// linked account; the scanner flatMaps all accounts. buildSessionRows must
    /// COLLAPSE those into ONE row whose `accounts` set carries every account it
    /// is reachable under, with a single stable Identifiable id.
    func testSameSessionIdUnderMultipleAccountsCollapsesToOneRowWithAccountSet() {
        let snap = snapshot(workspaces: [
            workspace("w", sessions: [
                session("dup", account: "default", title: "Shared"),
                session("dup", account: "work", title: "Shared"),
            ]),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:])
        XCTAssertEqual(rows.count, 1, "one collapsed row for the shared session")
        XCTAssertEqual(rows[0].sessionId, "dup")
        XCTAssertEqual(Set(rows[0].accounts), ["default", "work"],
                       "the row carries every account the session is reachable under")
    }

    /// The collapsed row's PRIMARY accountName is the LIVE owner when one account
    /// holds a live process (that's the account `--resume` should run under by
    /// default); ties otherwise break on first-seen.
    func testCollapsedRowPrimaryAccountIsTheLiveOwner() {
        let snap = snapshot(workspaces: [
            workspace("w",
                      sessions: [session("dup", account: "default"),
                                 session("dup", account: "work")],
                      live: [live(1, session: "dup", status: "busy", account: "work")]),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].accountName, "work", "the live account is the primary")
        XCTAssertEqual(rows[0].liveStatus, .busy)
        XCTAssertEqual(Set(rows[0].accounts), ["default", "work"])
    }

    /// An exact duplicate (same id AND same account) within one container collapses
    /// to a single row with a single account entry (no duplicate Identifiable, no
    /// duplicate account chip).
    func testExactDuplicateSessionInOneContainerCollapsesToOneRow() {
        let snap = snapshot(workspaces: [
            workspace("w", sessions: [
                session("same", account: "default", title: "First"),
                session("same", account: "default", title: "Second"),
            ]),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:])
        XCTAssertEqual(rows.count, 1, "identical (account, session) collapses")
        XCTAssertEqual(rows[0].accounts, ["default"], "account appears once")
        XCTAssertEqual(rows[0].title, "First", "first occurrence wins for stable fields")
    }

    /// The SAME (cwd, sessionId) can be reachable in two DIFFERENT containers — a
    /// workspace under one account AND a loose worktree under another — because the
    /// shared store makes the transcript visible from every linked account. Collapse
    /// must group GLOBALLY across all containers so the row's `accounts` set carries
    /// BOTH accounts; neither container's account may be dropped.
    func testSameSessionAcrossWorkspaceAndLooseContainersMergesBothAccounts() {
        let cwd = "/ws/shared-cwd"
        let snap = snapshot(
            workspaces: [
                workspace("w", sessions: [session("dup", account: "default", title: "Shared", cwd: cwd)]),
            ],
            loose: [
                loose("loose", sessions: [session("dup", account: "work", title: "Shared", cwd: cwd)]),
            ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:])
        XCTAssertEqual(rows.count, 1, "one collapsed row across both containers")
        XCTAssertEqual(rows[0].sessionId, "dup")
        XCTAssertEqual(Set(rows[0].accounts), ["default", "work"],
                       "both containers' accounts are merged; none is dropped")
    }

    // MARK: - Go carries the matched cmux workspace id (issue 2)

    func testGoActionCarriesCmuxWorkspaceIdFromHookMap() {
        let snap = snapshot(workspaces: [
            workspace("w", sessions: [session("s1")],
                      live: [live(1, session: "s1", status: "busy")]),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: ["s1": "ws-hook"])
        XCTAssertEqual(rows[0].action, .go)
        XCTAssertEqual(rows[0].cmuxWorkspaceId, "ws-hook")
    }

    func testGoActionCarriesCmuxWorkspaceIdFromCwdMatch() {
        let cwd = "/ws/media-upload"
        let snap = snapshot(workspaces: [
            workspace("media-upload", umbrella: cwd,
                      sessions: [session("s2", cwd: cwd)],
                      live: [live(7, session: "s2", status: "busy", cwd: cwd)],
                      cmux: [CmuxWorkspace(id: "cw-9", title: "media", currentDirectory: cwd)]),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:])
        XCTAssertEqual(rows[0].action, .go)
        XCTAssertEqual(rows[0].cmuxWorkspaceId, "cw-9",
                       "Go via the cwd-only path must carry the matched workspace id")
    }

    func testResumeRowHasNoCmuxWorkspaceId() {
        let snap = snapshot(workspaces: [
            workspace("w", sessions: [session("s3")]),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:])
        XCTAssertEqual(rows[0].action, .resume)
        XCTAssertNil(rows[0].cmuxWorkspaceId)
    }

    // MARK: - shell status is not a recognised live status (renders as idle-ish)

    func testUnknownStatusTreatedAsIdleBucket() {
        let snap = snapshot(workspaces: [
            workspace("w", sessions: [session("sh")],
                      live: [live(5, session: "sh", status: "shell")]),
        ])
        let rows = buildSessionRows(snapshot: snap, cmuxMap: [:])
        // unknown/shell status is still "live" but sorts in the idle bucket.
        XCTAssertEqual(rows[0].liveStatus, .idle)
    }
}
