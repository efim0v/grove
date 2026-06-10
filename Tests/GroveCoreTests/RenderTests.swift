import XCTest
@testable import GroveCore

final class RenderTests: XCTestCase {

    // MARK: - synthetic value builders (no git, no filesystem)

    private func meta(dirty: Int) -> WorktreeMeta {
        WorktreeMeta(baseBranch: "main", forkPoint: nil, forkDate: nil,
                     ahead: 0, behind: 0, dirtyCount: dirty,
                     lastCommitDate: nil, lastCommitSubject: nil)
    }

    private func state(repo: RepoInfo, branch: String, dirty: Int) -> WorkspaceRepoState {
        WorkspaceRepoState(
            repo: repo,
            entry: WorktreeEntry(path: "/ws/\(branch)", branch: branch, head: "deadbee", isMain: false),
            meta: meta(dirty: dirty),
            scanError: nil)
    }

    private func ws(_ name: String, parent: String?, states: [WorkspaceRepoState]) -> FeatureWorkspace {
        FeatureWorkspace(name: name, umbrellaPath: "/ws/\(name)", repos: states,
                         parentName: parent, sessions: [], liveProcesses: [], cmuxWorkspaces: [])
    }

    // MARK: - renderSnapshotTree

    func testRenderSnapshotTree() {
        let r1 = RepoInfo(path: "/tmp/demo/r1", dirName: "r1")
        let r2 = RepoInfo(path: "/tmp/demo/r2", dirName: "r2")
        let snapshot = ProjectSnapshot(
            project: ProjectConfig(name: "demo", path: "/tmp/demo"),
            repos: [r1, r2],
            workspaces: [
                ws("alpha", parent: nil, states: [state(repo: r1, branch: "feat/alpha", dirty: 3)]),
                ws("beta", parent: "alpha", states: [state(repo: r1, branch: "feat/beta", dirty: 0)]),
                ws("gamma", parent: nil, states: [state(repo: r2, branch: "feat/gamma", dirty: 0)]),
            ],
            loose: [
                LooseWorktree(
                    repo: r1,
                    entry: WorktreeEntry(path: "/tmp/demo/r1/.worktrees/old", branch: "hotfix",
                                         head: "cafef00", isMain: false),
                    meta: nil, sessions: [], liveProcesses: [], cmuxWorkspaces: [])
            ],
            errors: ["boom"])

        let expected = """
        demo — 2 repo(s), 3 workspace(s)
        ├─● alpha (feat/alpha) ✎3 · 1 repo(s)
        │ └─● beta (feat/beta) ✓ · 1 repo(s)
        └─● gamma (feat/gamma) ✓ · 1 repo(s)

        Loose worktrees (1)
          /tmp/demo/r1/.worktrees/old — r1 @ hotfix

        Errors (1)
          ⚠ boom
        """
        XCTAssertEqual(renderSnapshotTree(snapshot), expected)
    }

    func testRenderSnapshotTreeOrphanParentBecomesRoot() {
        // parentName pointing at a name missing from the snapshot -> rendered as a root.
        let r1 = RepoInfo(path: "/tmp/demo/r1", dirName: "r1")
        let snapshot = ProjectSnapshot(
            project: ProjectConfig(name: "demo", path: "/tmp/demo"),
            repos: [r1],
            workspaces: [ws("orphan", parent: "ghost",
                            states: [state(repo: r1, branch: "feat/orphan", dirty: 0)])],
            loose: [], errors: [])
        let expected = """
        demo — 1 repo(s), 1 workspace(s)
        └─● orphan (feat/orphan) ✓ · 1 repo(s)
        """
        XCTAssertEqual(renderSnapshotTree(snapshot), expected)
    }

    // MARK: - renderSessions

    func testRenderSessions() {
        let when = Date(timeIntervalSince1970: 1735689600) // 2025-01-01T00:00:00Z
        let sessions = [
            ClaudeSession(id: "sess-1", cwd: "/ws/alpha", title: "Fix media upload",
                          lastActivity: when, accountName: "default", gitBranch: "feat/media"),
            ClaudeSession(id: "sess-2", cwd: "/ws/alpha", title: nil,
                          lastActivity: when, accountName: "work", gitBranch: nil),
        ]
        let live = [LiveProcess(pid: 4242, sessionId: "sess-1", cwd: "/ws/alpha",
                                status: "busy", accountName: "default")]
        let expected = """
        ● busy  Fix media upload [feat/media]  default  2025-01-01T00:00:00Z
        ○ resumable  sess-2  work  2025-01-01T00:00:00Z
        """
        XCTAssertEqual(renderSessions(sessions, live: live), expected)
    }

    func testRenderSessionsEmpty() {
        XCTAssertEqual(renderSessions([], live: []), "no sessions")
    }

    func testRenderSessionsLiveWithoutSessionRecord() {
        let live = [LiveProcess(pid: 7, sessionId: "ghost", cwd: "/ws/x",
                                status: "idle", accountName: "default")]
        let expected = "● idle  pid 7  default  /ws/x"
        XCTAssertEqual(renderSessions([], live: live), expected)
    }

    // MARK: - renderGraph

    func testRenderGraph() {
        let when = Date(timeIntervalSince1970: 1735689600)
        let nodes = [
            CommitNode(hash: "aaaaaaa1111", parents: ["ccccccc1111"], author: "t", date: when,
                       refs: ["HEAD -> main", "main"], subject: "merge feature", lane: 0),
            CommitNode(hash: "bbbbbbb2222", parents: ["ccccccc1111"], author: "t", date: when,
                       refs: ["feat/x"], subject: "feature commit", lane: 1),
            CommitNode(hash: "ccccccc1111", parents: [], author: "t", date: when,
                       refs: [], subject: "base", lane: 0),
        ]
        let expected = """
        * aaaaaaa (HEAD -> main, main) merge feature
        | * bbbbbbb (feat/x) feature commit
        * ccccccc base
        """
        XCTAssertEqual(renderGraph(nodes), expected)
    }
}
