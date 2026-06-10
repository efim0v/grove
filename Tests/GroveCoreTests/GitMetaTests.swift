import XCTest
@testable import GroveCore

final class GitMetaTests: XCTestCase {

    func testMetaOnForkedDirtyWorktree() async throws {
        let tmp = try Fixture.tempDir("git-meta")
        let repo = try Fixture.makeRepo(in: tmp, name: "repo") // main @ commit "base"

        // Fork feat/x from main, then let main advance by 1 commit.
        let wt = tmp.appendingPathComponent("wt-feature")
        try Fixture.addWorktree(repo: repo, branch: "feat/x", from: "main", at: wt)
        try Fixture.commit(repo: repo, file: "main-only.txt", content: "m", message: "main advance")

        // 3 commits on the branch (made inside the worktree).
        try Fixture.commit(repo: wt, file: "a.txt", content: "1", message: "feat a")
        try Fixture.commit(repo: wt, file: "b.txt", content: "2", message: "feat b")
        try Fixture.commit(repo: wt, file: "c.txt", content: "3", message: "feat c")

        // Dirty the worktree: modify 2 tracked files without committing.
        try "dirty".write(to: wt.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "dirty".write(to: wt.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let expectedFork = try Fixture.sh("git merge-base main feat/x", cwd: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let head = try Fixture.sh("git rev-parse feat/x", cwd: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let git = GitService()
        let entry = WorktreeEntry(path: wt.path, branch: "feat/x", head: head, isMain: false)
        let meta = await git.meta(repoPath: repo.path, worktree: entry, relativeTo: "main")

        XCTAssertEqual(meta.baseBranch, "main")
        XCTAssertEqual(meta.forkPoint, expectedFork, "fork point must equal git merge-base main feat/x")
        XCTAssertEqual(meta.ahead, 3, "3 commits on feat/x that are not on main")
        XCTAssertEqual(meta.behind, 1, "main advanced by 1 commit after the fork")
        XCTAssertEqual(meta.dirtyCount, 2)
        XCTAssertNotNil(meta.forkDate)
        XCTAssertNotNil(meta.lastCommitDate)
        XCTAssertEqual(meta.lastCommitSubject, "feat c")
    }

    func testMetaDegradesWithoutThrowingWhenBaseMissing() async throws {
        let tmp = try Fixture.tempDir("git-meta-degrade")
        let repo = try Fixture.makeRepo(in: tmp, name: "repo")
        let wt = tmp.appendingPathComponent("wt-y")
        try Fixture.addWorktree(repo: repo, branch: "feat/y", from: "main", at: wt)
        let head = try Fixture.sh("git rev-parse feat/y", cwd: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let git = GitService()
        let entry = WorktreeEntry(path: wt.path, branch: "feat/y", head: head, isMain: false)
        let meta = await git.meta(repoPath: repo.path, worktree: entry, relativeTo: "no-such-branch")

        XCTAssertEqual(meta.baseBranch, "no-such-branch")
        XCTAssertNil(meta.forkPoint)
        XCTAssertNil(meta.forkDate)
        XCTAssertEqual(meta.ahead, 0)
        XCTAssertEqual(meta.behind, 0)
        XCTAssertEqual(meta.dirtyCount, 0)
        // Fields that do not depend on the base are still populated.
        XCTAssertEqual(meta.lastCommitSubject, "base")
        XCTAssertNotNil(meta.lastCommitDate)
    }
}
