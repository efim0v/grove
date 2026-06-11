import XCTest
import GroveCore
@testable import GroveAppKit

final class FlatOrderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: fixtures

    private func session(_ id: String, age: TimeInterval) -> ClaudeSession {
        ClaudeSession(id: id, cwd: "/ws", title: "t", lastActivity: now.addingTimeInterval(-age),
                      accountName: "default", gitBranch: nil)
    }

    private func repoState(lastCommitAge: TimeInterval?) -> WorkspaceRepoState {
        let repo = RepoInfo(path: "/project/app", dirName: "app")
        let entry = WorktreeEntry(path: "/ws/app", branch: "feat/x", head: "abc123", isMain: false)
        let meta = WorktreeMeta(baseBranch: "main", forkPoint: "f0",
                                forkDate: now.addingTimeInterval(-86_400),
                                ahead: 1, behind: 0, dirtyCount: 0,
                                lastCommitDate: lastCommitAge.map { now.addingTimeInterval(-$0) },
                                lastCommitSubject: "subject")
        return WorkspaceRepoState(repo: repo, entry: entry, meta: meta, scanError: nil)
    }

    private func workspace(_ name: String, sessions: [ClaudeSession],
                           lastCommitAge: TimeInterval?) -> FeatureWorkspace {
        FeatureWorkspace(name: name, umbrellaPath: "/ws/\(name)",
                         repos: [repoState(lastCommitAge: lastCommitAge)],
                         parentName: nil, sessions: sessions,
                         liveProcesses: [], cmuxWorkspaces: [])
    }

    private func rows(_ workspaces: [FeatureWorkspace]) -> [WorkspaceTreeRow] {
        let project = ProjectConfig(name: "p", path: "/project")
        let snapshot = ProjectSnapshot(project: project, repos: [],
                                       workspaces: workspaces, loose: [], errors: [])
        return buildWorkspaceTree(snapshot, now: now)
    }

    // MARK: recencyDate

    func testRecencyDatePicksMaxAcrossSessionsAndCommits() {
        let ws = workspace("gamma",
                           sessions: [session("s1", age: 9_000), session("s2", age: 4_000)],
                           lastCommitAge: 2_000)
        XCTAssertEqual(recencyDate(ws), now.addingTimeInterval(-2_000))
    }

    func testRecencyDateNilWithoutAnyDates() {
        let ws = workspace("empty", sessions: [], lastCommitAge: nil)
        XCTAssertNil(recencyDate(ws))
    }

    // MARK: flattenByRecency

    func testNewerCommitBeatsOlderSession() {
        let alpha = workspace("alpha", sessions: [session("s1", age: 3_600)], lastCommitAge: 50_000)
        let beta = workspace("beta", sessions: [], lastCommitAge: 600)
        let sorted = flattenByRecency(rows([alpha, beta]))
        XCTAssertEqual(sorted.map(\.name), ["beta", "alpha"])
    }

    func testWorkspaceWithoutDatesSinksToBottom() {
        let alpha = workspace("alpha", sessions: [], lastCommitAge: nil)
        let beta = workspace("beta", sessions: [session("s", age: 90_000)], lastCommitAge: nil)
        let sorted = flattenByRecency(rows([alpha, beta]))
        XCTAssertEqual(sorted.map(\.name), ["beta", "alpha"])
    }

    func testTieBreaksAlphabetically() {
        let beta = workspace("beta", sessions: [session("s1", age: 7_200)], lastCommitAge: nil)
        let alpha = workspace("alpha", sessions: [session("s2", age: 7_200)], lastCommitAge: nil)
        let sorted = flattenByRecency(rows([beta, alpha]))
        XCTAssertEqual(sorted.map(\.name), ["alpha", "beta"])
    }
}
