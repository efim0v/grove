import XCTest
@testable import GroveCore

/// Regression coverage for a Swift 6.3.2 release-mode (-O) miscompilation.
///
/// scan()'s worktree task group originally had children returning the bare
/// tuple `(repo, try await git.worktrees(repo: repo), nil)` inside a do/catch.
/// Under -O that closure shape was miscompiled: the child's future result was
/// silently dropped (the group's `for await` yielded NOTHING, so scan returned
/// zero workspaces with zero errors) and the CLI intermittently aborted with
/// "libc++abi: Pure virtual function called!" in
/// swift::AsyncTask::completeFuture. Debug builds were unaffected.
///
/// collectWorktrees now uses a named Sendable result struct and hoists the
/// awaited call into a local, which avoids the broken codegen. This test runs
/// the group repeatedly in release CI; if the old shape is ever reintroduced,
/// it fails deterministically (the original repro lost 30 of 30 rounds).
final class ScanWorktreeCollectionTests: XCTestCase {

    func testCollectWorktreesNeverDropsChildResults() async throws {
        let base = try Fixture.tempDir("collect-worktrees").resolvingSymlinksInPath()
        let repo = try Fixture.makeRepo(in: base, name: "r")
        try Fixture.addWorktree(repo: repo, branch: "feat/x", from: "main",
                                at: base.appendingPathComponent("wt"))

        let service = WorkspaceService(git: GitService(), claude: ClaudeService(),
                                       cmux: CmuxService(), config: GroveConfig.defaultConfig)
        let repos = [RepoInfo(path: repo.path, dirName: "r")]

        for round in 0..<30 {
            let (byRepo, errors) = await service.collectWorktrees(repos: repos)
            XCTAssertEqual(errors, [], "round \(round)")
            XCTAssertEqual(byRepo[repos[0]]?.count, 2,
                           "round \(round): task-group child result was dropped")
        }
    }

    func testCollectWorktreesDegradesFailuresToErrors() async throws {
        // A path that is not a git repo -> worktrees() throws -> error string.
        let base = try Fixture.tempDir("collect-worktrees-fail").resolvingSymlinksInPath()
        let service = WorkspaceService(git: GitService(), claude: ClaudeService(),
                                       cmux: CmuxService(), config: GroveConfig.defaultConfig)
        let repos = [RepoInfo(path: base.path, dirName: "not-a-repo")]

        let (byRepo, errors) = await service.collectWorktrees(repos: repos)
        XCTAssertEqual(byRepo[repos[0]], [])
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.hasPrefix("worktrees not-a-repo:") ?? false,
                      "got: \(errors)")
    }
}
