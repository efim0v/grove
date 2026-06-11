import Foundation
import XCTest
@testable import GroveCore

final class GitWorktreeTests: XCTestCase {
    private let git = GitService()

    /// git prints symlink-resolved worktree paths (/private/var/... on macOS);
    /// fixtures live under /var/... — normalize both sides before comparing.
    private func norm(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func repoInfo(_ url: URL) -> RepoInfo {
        RepoInfo(path: url.path, dirName: url.lastPathComponent)
    }

    // MARK: - worktree list --porcelain

    func testWorktreeListPorcelainParsing() async throws {
        let dir = try Fixture.tempDir("wt-parse")
        let repo = try Fixture.makeRepo(in: dir, name: "alpha")
        try Fixture.commit(repo: repo, file: "f.txt", content: "1", message: "c1")

        let wtBranch = dir.appendingPathComponent("wt-branch")
        try Fixture.addWorktree(repo: repo, branch: "feat/a", from: "main", at: wtBranch)
        let wtDetached = dir.appendingPathComponent("wt-detached")
        try Fixture.sh("git -C \(shellQuote(repo.path)) worktree add --detach \(shellQuote(wtDetached.path)) main")

        let entries = try await git.worktrees(repo: repoInfo(repo))
        XCTAssertEqual(entries.count, 3)

        // git lists the main worktree first.
        let main = entries[0]
        XCTAssertTrue(main.isMain)
        XCTAssertEqual(norm(main.path), norm(repo.path))
        XCTAssertEqual(main.branch, "main")

        let branched = try XCTUnwrap(entries.first { norm($0.path) == norm(wtBranch.path) })
        XCTAssertEqual(branched.branch, "feat/a")
        XCTAssertFalse(branched.isMain)

        let detached = try XCTUnwrap(entries.first { norm($0.path) == norm(wtDetached.path) })
        XCTAssertNil(detached.branch)
        XCTAssertFalse(detached.isMain)

        let head = try Fixture.sh("git -C \(shellQuote(repo.path)) rev-parse HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(main.head, head)
        XCTAssertEqual(branched.head, head)
        XCTAssertEqual(detached.head, head)
    }

    // MARK: - baseBranch

    func testBaseBranchOverrideWins() async throws {
        let dir = try Fixture.tempDir("base-override")
        let repo = try Fixture.makeRepo(in: dir, name: "alpha") // default branch "main" exists
        let base = await git.baseBranch(repo: repoInfo(repo), override: "docker")
        XCTAssertEqual(base, "docker") // override beats every other source
    }

    func testBaseBranchUsesOriginHead() async throws {
        let dir = try Fixture.tempDir("base-origin")
        // "trunk" is NOT in the main/master/dev fallback chain, so the result can
        // only come from refs/remotes/origin/HEAD.
        let upstream = try Fixture.makeRepo(in: dir, name: "upstream", defaultBranch: "trunk")
        let bare = dir.appendingPathComponent("upstream.git")
        try Fixture.sh("git clone -q --bare \(shellQuote(upstream.path)) \(shellQuote(bare.path))")
        let clone = dir.appendingPathComponent("clone")
        try Fixture.sh("git clone -q \(shellQuote(bare.path)) \(shellQuote(clone.path))")
        // git clone sets origin/HEAD itself; pin it explicitly so the test is
        // deterministic regardless of clone defaults.
        try Fixture.sh("git -C \(shellQuote(clone.path)) symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk")

        let base = await git.baseBranch(repo: repoInfo(clone), override: nil)
        XCTAssertEqual(base, "trunk")

        let overridden = await git.baseBranch(repo: repoInfo(clone), override: "docker")
        XCTAssertEqual(overridden, "docker") // override beats origin/HEAD too
    }

    func testBaseBranchFallbackChain() async throws {
        let dir = try Fixture.tempDir("base-fallback")
        let masterRepo = try Fixture.makeRepo(in: dir, name: "m", defaultBranch: "master")
        let devRepo = try Fixture.makeRepo(in: dir, name: "d", defaultBranch: "dev")
        let trunkRepo = try Fixture.makeRepo(in: dir, name: "t", defaultBranch: "trunk")

        let masterBase = await git.baseBranch(repo: repoInfo(masterRepo), override: nil)
        XCTAssertEqual(masterBase, "master") // no origin, no main -> master
        let devBase = await git.baseBranch(repo: repoInfo(devRepo), override: nil)
        XCTAssertEqual(devBase, "dev") // no origin, no main/master -> dev
        let trunkBase = await git.baseBranch(repo: repoInfo(trunkRepo), override: nil)
        XCTAssertEqual(trunkBase, "main") // none of main/master/dev exist -> hardcoded "main"
    }

    // MARK: - branchExists

    func testBranchExists() async throws {
        let dir = try Fixture.tempDir("branch-exists")
        let repo = try Fixture.makeRepo(in: dir, name: "alpha")
        let yes = await git.branchExists(repoPath: repo.path, "main")
        XCTAssertTrue(yes)
        let no = await git.branchExists(repoPath: repo.path, "does-not-exist")
        XCTAssertFalse(no)
    }

    // MARK: - addWorktree / removeWorktree / deleteBranch

    func testAddWorktreeCreateBranchThenDoubleCheckoutFails() async throws {
        let dir = try Fixture.tempDir("wt-add")
        let repo = try Fixture.makeRepo(in: dir, name: "alpha")
        let info = repoInfo(repo)
        let fm = FileManager.default

        // createBranch: true -> git worktree add -b feat/x <path> main
        let first = dir.appendingPathComponent("ws").appendingPathComponent("feat-x").appendingPathComponent("alpha")
        try fm.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git.addWorktree(repoPath: info.path, branch: "feat/x", startPoint: "main",
                                  at: first.path, createBranch: true)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: first.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        // Worktree checkout marker: .git is a FILE, not a directory.
        XCTAssertTrue(fm.fileExists(atPath: first.appendingPathComponent(".git").path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
        let created = await git.branchExists(repoPath: info.path, "feat/x")
        XCTAssertTrue(created)

        // git forbids checking out one branch in two worktrees -> must throw.
        let second = dir.appendingPathComponent("ws").appendingPathComponent("feat-x-again").appendingPathComponent("alpha")
        try fm.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try await git.addWorktree(repoPath: info.path, branch: "feat/x", startPoint: "main",
                                      at: second.path, createBranch: false)
            XCTFail("expected addWorktree to throw: feat/x is already checked out in another worktree")
        } catch GroveError.processFailed(_, let exitCode, let stderr) {
            XCTAssertNotEqual(exitCode, 0)
            XCTAssertTrue(stderr.contains("already"), "unexpected git error: \(stderr)")
        }
    }

    // MARK: - localBranches

    func testLocalBranchesReturnsSortedNames() async throws {
        let dir = try Fixture.tempDir("local-branches")
        let repo = try Fixture.makeRepo(in: dir, name: "alpha")
        // Create two extra branches in non-alphabetical order.
        try Fixture.sh("git -C \(shellQuote(repo.path)) branch zebra")
        try Fixture.sh("git -C \(shellQuote(repo.path)) branch apple")
        // Now repo has: apple, main, zebra
        let branches = await git.localBranches(repoPath: repo.path)
        XCTAssertEqual(branches, ["apple", "main", "zebra"])
    }

    func testLocalBranchesNonexistentPathReturnsEmpty() async {
        let branches = await git.localBranches(repoPath: "/nonexistent/path/\(UUID().uuidString)")
        XCTAssertEqual(branches, [])
    }

    func testAddExistingBranchWorktreeThenRemoveAndDeleteBranch() async throws {
        let dir = try Fixture.tempDir("wt-lifecycle")
        let repo = try Fixture.makeRepo(in: dir, name: "alpha")
        let info = repoInfo(repo)
        let fm = FileManager.default

        // A DIFFERENT pre-existing branch (not checked out anywhere) succeeds with createBranch: false.
        try Fixture.sh("git -C \(shellQuote(repo.path)) branch feat/y main")
        let wt = dir.appendingPathComponent("ws").appendingPathComponent("feat-y").appendingPathComponent("alpha")
        try fm.createDirectory(at: wt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git.addWorktree(repoPath: info.path, branch: "feat/y", startPoint: "main",
                                  at: wt.path, createBranch: false)
        let checkedOut = try Fixture.sh("git -C \(shellQuote(wt.path)) rev-parse --abbrev-ref HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(checkedOut, "feat/y")
        var entries = try await git.worktrees(repo: info)
        XCTAssertEqual(entries.count, 2)

        // Remove using the git-reported path (symlink-resolved on macOS).
        let wtEntry = try XCTUnwrap(entries.first { !$0.isMain })
        try await git.removeWorktree(repoPath: info.path, at: wtEntry.path, force: false)
        entries = try await git.worktrees(repo: info)
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: wt.path))

        // Removing the worktree keeps its branch; deleteBranch removes it.
        var exists = await git.branchExists(repoPath: info.path, "feat/y")
        XCTAssertTrue(exists)
        try await git.deleteBranch(repoPath: info.path, "feat/y")
        exists = await git.branchExists(repoPath: info.path, "feat/y")
        XCTAssertFalse(exists)
    }
}
