import XCTest
import GroveCore
import GroveAppKit

final class AccountUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let defaultAccount = AccountConfig(name: "default", configDir: "~/.claude")
    private let workAccount = AccountConfig(name: "work", configDir: "~/.claude-accounts/work")

    // MARK: - fixture builders (self-contained)

    private func session(_ id: String, account: String, cwd: String = "/ws") -> ClaudeSession {
        ClaudeSession(id: id, cwd: cwd, title: nil, lastActivity: now,
                      accountName: account, gitBranch: nil)
    }

    private func live(_ pid: Int32, session: String, account: String) -> LiveProcess {
        LiveProcess(pid: pid, sessionId: session, cwd: "/ws", status: "busy",
                    accountName: account)
    }

    private func workspace(_ name: String, sessions: [ClaudeSession],
                           live: [LiveProcess]) -> FeatureWorkspace {
        FeatureWorkspace(name: name, umbrellaPath: "/ws/\(name)", repos: [],
                         parentName: nil, sessions: sessions, liveProcesses: live,
                         cmuxWorkspaces: [])
    }

    private func loose(_ leaf: String, repoDir: String, sessions: [ClaudeSession]) -> LooseWorktree {
        let repo = RepoInfo(path: "/p/\(repoDir)", dirName: repoDir)
        return LooseWorktree(
            repo: repo,
            entry: WorktreeEntry(path: "/p/\(repoDir)/.worktrees/\(leaf)",
                                 branch: leaf, head: "abc", isMain: false),
            meta: nil, sessions: sessions, liveProcesses: [], cmuxWorkspaces: [])
    }

    private func snapshot(_ projectName: String, workspaces: [FeatureWorkspace],
                          loose: [LooseWorktree] = []) -> ProjectSnapshot {
        ProjectSnapshot(project: ProjectConfig(name: projectName, path: "/p"),
                        repos: [], workspaces: workspaces, loose: loose, errors: [])
    }

    // MARK: - tests

    func testCountsOnlyTheAccountsOwnActivity() {
        let snap = snapshot("alpha", workspaces: [
            workspace("w1",
                      sessions: [session("s1", account: "default"),
                                 session("s2", account: "work")],
                      live: [live(1, session: "s1", account: "default")]),
        ])
        let usage = accountUsage(account: defaultAccount, snapshots: [snap])
        XCTAssertEqual(usage.liveCount, 1)
        XCTAssertEqual(usage.sessionCount, 1)
        XCTAssertEqual(usage.entries,
                       [AccountUsageEntry(project: "alpha", location: "w1",
                                          liveCount: 1, sessionCount: 1)])
    }

    func testAggregatesAcrossSnapshotsAndLooseWorktrees() {
        let snapA = snapshot("alpha",
                             workspaces: [workspace("w1",
                                                    sessions: [session("s1", account: "work")],
                                                    live: [])],
                             loose: [loose("group-chats", repoDir: "client",
                                           sessions: [session("s2", account: "work")])])
        let snapB = snapshot("beta", workspaces: [
            workspace("w2",
                      sessions: [session("s3", account: "work")],
                      live: [live(9, session: "s3", account: "work")]),
        ])
        let usage = accountUsage(account: workAccount, snapshots: [snapA, snapB])
        XCTAssertEqual(usage.liveCount, 1)
        XCTAssertEqual(usage.sessionCount, 3)
        // live first, then session count, then location name.
        XCTAssertEqual(usage.entries.map(\.location), ["w2", "group-chats", "w1"])
        XCTAssertEqual(usage.entries.map(\.project), ["beta", "alpha", "alpha"])
    }

    func testLocationsWithoutActivityAreOmitted() {
        let snap = snapshot("alpha", workspaces: [
            workspace("busy", sessions: [session("s1", account: "default")], live: []),
            workspace("idle", sessions: [], live: []),
        ])
        let usage = accountUsage(account: defaultAccount, snapshots: [snap])
        XCTAssertEqual(usage.entries.map(\.location), ["busy"])
    }

    func testUnknownAccountHasZeroUsage() {
        let snap = snapshot("alpha", workspaces: [
            workspace("w1", sessions: [session("s1", account: "default")], live: []),
        ])
        let usage = accountUsage(account: AccountConfig(name: "ghost", configDir: "~/x"),
                                 snapshots: [snap])
        XCTAssertEqual(usage, AccountUsage(liveCount: 0, sessionCount: 0, entries: []))
    }

    func testOrderIsDeterministicRegardlessOfSnapshotOrder() {
        let snapA = snapshot("alpha", workspaces: [
            workspace("w-a", sessions: [session("s1", account: "default")], live: []),
        ])
        let snapB = snapshot("beta", workspaces: [
            workspace("w-b", sessions: [session("s2", account: "default")], live: []),
        ])
        XCTAssertEqual(accountUsage(account: defaultAccount, snapshots: [snapA, snapB]).entries,
                       accountUsage(account: defaultAccount, snapshots: [snapB, snapA]).entries)
    }

    @MainActor
    func testFixtureStateUsageMatchesAccountsScreenExpectations() {
        // Locks the numbers asserted visually in accounts.png.
        let state = SnapshotMode.fixtureState()
        let snapshots = Array(state.snapshots.values)
        let defaultUsage = accountUsage(account: defaultAccount, snapshots: snapshots)
        XCTAssertEqual(defaultUsage.liveCount, 1)        // busy in media-pipeline
        XCTAssertEqual(defaultUsage.sessionCount, 4)     // mp, mu, ff, loose group-chats
        XCTAssertEqual(defaultUsage.entries.first?.location, "media-pipeline")
        let workUsage = accountUsage(account: workAccount, snapshots: snapshots)
        XCTAssertEqual(workUsage.liveCount, 1)           // waiting in media-upload
        XCTAssertEqual(workUsage.sessionCount, 2)        // media-upload + folders-followup
        XCTAssertEqual(workUsage.entries.map(\.location), ["media-upload", "folders-followup"])
    }
}
