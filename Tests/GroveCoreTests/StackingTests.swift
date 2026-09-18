import XCTest
@testable import GroveCore

final class StackingTests: XCTestCase {

    // MARK: mergeBase against a real stacked-branch fixture

    func testMergeBaseDistinguishesStackedWorkspaceFromBaseFork() async throws {
        let tmp = try Fixture.tempDir("stacking")
        let repo = try Fixture.makeRepo(in: tmp, name: "repo") // main @ commit "base"

        // A forked from main with 2 commits of its own.
        let wtA = tmp.appendingPathComponent("wt-A")
        try Fixture.addWorktree(repo: repo, branch: "feat/A", from: "main", at: wtA)
        try Fixture.commit(repo: wtA, file: "a1.txt", content: "1", message: "A1")
        try Fixture.commit(repo: wtA, file: "a2.txt", content: "2", message: "A2")

        // B stacked on A.
        let wtB = tmp.appendingPathComponent("wt-B")
        try Fixture.addWorktree(repo: repo, branch: "feat/B", from: "feat/A", at: wtB)
        try Fixture.commit(repo: wtB, file: "b1.txt", content: "1", message: "B1")

        // C forked straight from main.
        let wtC = tmp.appendingPathComponent("wt-C")
        try Fixture.addWorktree(repo: repo, branch: "feat/C", from: "main", at: wtC)
        try Fixture.commit(repo: wtC, file: "c1.txt", content: "1", message: "C1")

        let git = GitService()

        // Stacked: merge-base(B, A) is A's tip, merge-base(B, main) is the root -> different.
        let mbBA = await git.mergeBase(repoPath: repo.path, "feat/B", "feat/A")
        let mbBMain = await git.mergeBase(repoPath: repo.path, "feat/B", "main")
        XCTAssertNotNil(mbBA)
        XCTAssertNotNil(mbBMain)
        XCTAssertNotEqual(mbBA, mbBMain, "B forked from A: merge-base(B,A) != merge-base(B,main)")
        let tipA = try Fixture.sh("git rev-parse feat/A", cwd: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(mbBA, tipA)

        // Not stacked: merge-base(C, A) == merge-base(C, main) (both are the fork point on main).
        let mbCA = await git.mergeBase(repoPath: repo.path, "feat/C", "feat/A")
        let mbCMain = await git.mergeBase(repoPath: repo.path, "feat/C", "main")
        XCTAssertNotNil(mbCA)
        XCTAssertEqual(mbCA, mbCMain, "C forked from main: merge-base values must be equal")
    }

    /// The staircase bug: three workspaces forked from `main` at different times.
    /// merge-base(later, earlier) is the EARLIER fork point — on main — and differs
    /// from the later one's own fork point, which the old rule read as "stacked".
    /// What separates a sibling from a stack is whether that merge-base lies off base.
    func testSiblingsForkedFromAMovingBaseAreNotStacked() async throws {
        let tmp = try Fixture.tempDir("stacking-siblings")
        let repo = try Fixture.makeRepo(in: tmp, name: "repo")
        let wtA = tmp.appendingPathComponent("wt-A")
        try Fixture.addWorktree(repo: repo, branch: "feat/A", from: "main", at: wtA)
        try Fixture.commit(repo: wtA, file: "a1.txt", content: "1", message: "A1")
        // main moves on.
        try Fixture.commit(repo: repo, file: "m2.txt", content: "2", message: "M2")
        let wtB = tmp.appendingPathComponent("wt-B")
        try Fixture.addWorktree(repo: repo, branch: "feat/B", from: "main", at: wtB)
        try Fixture.commit(repo: wtB, file: "b1.txt", content: "1", message: "B1")
        // C really is stacked on A.
        let wtC = tmp.appendingPathComponent("wt-C")
        try Fixture.addWorktree(repo: repo, branch: "feat/C", from: "feat/A", at: wtC)
        try Fixture.commit(repo: wtC, file: "c1.txt", content: "1", message: "C1")

        let git = GitService()
        let mbBAValue = await git.mergeBase(repoPath: repo.path, "feat/B", "feat/A")
        let mbBMainValue = await git.mergeBase(repoPath: repo.path, "feat/B", "main")
        let mbBA = try XCTUnwrap(mbBAValue)
        let mbBMain = try XCTUnwrap(mbBMainValue)
        XCTAssertNotEqual(mbBA, mbBMain, "the old rule's premise: the two merge-bases differ")
        let onBase = await git.isAncestor(repoPath: repo.path, mbBA, of: "main")
        XCTAssertTrue(onBase, "…yet the shared merge-base is on main: B carries nothing of A's")
        let mbCAValue = await git.mergeBase(repoPath: repo.path, "feat/C", "feat/A")
        let mbCA = try XCTUnwrap(mbCAValue)
        let stacked = await git.isAncestor(repoPath: repo.path, mbCA, of: "main")
        XCTAssertFalse(stacked, "C's merge-base with A is A's own commit, off main: stacked")
        let unknown = await git.isAncestor(repoPath: repo.path, "no-such-ref", of: "main")
        XCTAssertFalse(unknown)
    }

    func testMergeBaseReturnsNilForUnknownRef() async throws {
        let tmp = try Fixture.tempDir("stacking-nil")
        let repo = try Fixture.makeRepo(in: tmp, name: "repo")
        let git = GitService()
        let mb = await git.mergeBase(repoPath: repo.path, "main", "no-such-ref")
        XCTAssertNil(mb)
    }

    // MARK: resolveParentName (pure)

    func testResolveParentNameDeepestDepthWins() {
        let parent = resolveParentName(candidates: [
            (name: "alpha", depth: 2),
            (name: "beta", depth: 5),
            (name: "gamma", depth: 3),
        ])
        XCTAssertEqual(parent, "beta")
    }

    func testResolveParentNameTieBreaksAlphabetically() {
        let parent = resolveParentName(candidates: [
            (name: "zeta", depth: 4),
            (name: "alpha", depth: 4),
            (name: "mid", depth: 4),
        ])
        XCTAssertEqual(parent, "alpha")
    }

    func testResolveParentNameEmptyCandidates() {
        XCTAssertNil(resolveParentName(candidates: []))
    }
}
