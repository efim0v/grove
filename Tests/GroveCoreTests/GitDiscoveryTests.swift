import Foundation
import XCTest
@testable import GroveCore

final class GitDiscoveryTests: XCTestCase {
    private let git = GitService()

    /// Builds this tree (repos marked *):
    ///
    ///     <tmp>/
    ///       outside/                  * repo OUTSIDE the project (worktree source)
    ///       project/
    ///         alpha/                  * repo, depth 1
    ///         zeta/                   * repo, depth 1 (excluded by name in one test)
    ///         sub1/sub2/beta/         * repo, depth 3
    ///         sub1/sub2/sub3/gamma/   * repo, depth 4 — beyond scanDepth 3
    ///         wt-checkout/              worktree of `outside` (.git is a FILE) — never a repo
    ///         node_modules/nm-repo/   * repo under always-skipped dir — never found
    ///         .worktrees/wt-repo/     * repo under always-skipped dir — never found
    ///         .hidden/hidden-repo/    * repo under hidden dir — never found
    private func makeProjectTree() throws -> URL {
        let tmp = try Fixture.tempDir("discovery")
        let project = tmp.appendingPathComponent("project")
        let sub1 = project.appendingPathComponent("sub1")
        let sub2 = sub1.appendingPathComponent("sub2")
        let sub3 = sub2.appendingPathComponent("sub3")
        let fm = FileManager.default
        try fm.createDirectory(at: sub3, withIntermediateDirectories: true)
        try fm.createDirectory(at: project.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try fm.createDirectory(at: project.appendingPathComponent(".worktrees"), withIntermediateDirectories: true)
        try fm.createDirectory(at: project.appendingPathComponent(".hidden"), withIntermediateDirectories: true)

        _ = try Fixture.makeRepo(in: project, name: "alpha")
        _ = try Fixture.makeRepo(in: project, name: "zeta")
        _ = try Fixture.makeRepo(in: sub2, name: "beta")
        _ = try Fixture.makeRepo(in: sub3, name: "gamma")
        _ = try Fixture.makeRepo(in: project.appendingPathComponent("node_modules"), name: "nm-repo")
        _ = try Fixture.makeRepo(in: project.appendingPathComponent(".worktrees"), name: "wt-repo")
        _ = try Fixture.makeRepo(in: project.appendingPathComponent(".hidden"), name: "hidden-repo")

        let outside = try Fixture.makeRepo(in: tmp, name: "outside")
        try Fixture.addWorktree(repo: outside, branch: "wt", from: "main",
                                at: project.appendingPathComponent("wt-checkout"))
        return project
    }

    func testFindsReposAtDepth1And3SkipsDeeperHiddenSkippedAndWorktreeCheckouts() async throws {
        let project = try makeProjectTree()
        let repos = await git.discoverRepos(projectPath: project.path, scanDepth: 3, excluded: [])
        // gamma (depth 4), wt-checkout (.git FILE), node_modules/.worktrees/.hidden subtrees: all absent.
        XCTAssertEqual(repos.map(\.dirName), ["alpha", "beta", "zeta"])
        XCTAssertEqual(repos.map(\.path), [
            project.appendingPathComponent("alpha").path,
            project.appendingPathComponent("sub1").appendingPathComponent("sub2").appendingPathComponent("beta").path,
            project.appendingPathComponent("zeta").path,
        ])
    }

    func testScanDepth4FindsTheDepth4Repo() async throws {
        let project = try makeProjectTree()
        let repos = await git.discoverRepos(projectPath: project.path, scanDepth: 4, excluded: [])
        XCTAssertEqual(repos.map(\.dirName), ["alpha", "beta", "gamma", "zeta"])
    }

    func testHonorsExcludedSetByDirName() async throws {
        let project = try makeProjectTree()
        let repos = await git.discoverRepos(projectPath: project.path, scanDepth: 3, excluded: ["zeta"])
        XCTAssertEqual(repos.map(\.dirName), ["alpha", "beta"])
    }
}
