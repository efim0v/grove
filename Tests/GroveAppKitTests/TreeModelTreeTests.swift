import XCTest
import GroveCore
import GroveAppKit

final class TreeModelTreeTests: XCTestCase {

    func testRootsOnlySortedByName() {
        let snap = Fix.snapshot(workspaces: [
            Fix.workspace(name: "zeta"),
            Fix.workspace(name: "alpha"),
        ])
        let rows = buildWorkspaceTree(snap, now: Fix.now)
        XCTAssertEqual(rows.map { $0.name }, ["alpha", "zeta"])
        XCTAssertEqual(rows.map { $0.depth }, [0, 0])
        XCTAssertEqual(rows.map { $0.isLast }, [false, true])
        XCTAssertEqual(rows.map { $0.ancestorContinues }, [[], []])
    }

    func testDFSPreOrderWithChildrenSortedByName() {
        // root
        // ├─ kid-a
        // │  └─ grand
        // └─ kid-b          (input deliberately shuffled)
        let snap = Fix.snapshot(workspaces: [
            Fix.workspace(name: "kid-b", parent: "root"),
            Fix.workspace(name: "root"),
            Fix.workspace(name: "grand", parent: "kid-a"),
            Fix.workspace(name: "kid-a", parent: "root"),
        ])
        let rows = buildWorkspaceTree(snap, now: Fix.now)
        XCTAssertEqual(rows.map { $0.name }, ["root", "kid-a", "grand", "kid-b"])
        XCTAssertEqual(rows.map { $0.depth }, [0, 1, 2, 1])
    }

    func testConnectorFlags() {
        // a            isLast=false
        // ├─ a1        isLast=false  ancestors: [a continues]
        // │  └─ a1x    isLast=true   ancestors: [a continues, a1 continues]
        // └─ a2        isLast=true   ancestors: [a continues]
        // b            isLast=true
        let snap = Fix.snapshot(workspaces: [
            Fix.workspace(name: "a"),
            Fix.workspace(name: "a1", parent: "a"),
            Fix.workspace(name: "a1x", parent: "a1"),
            Fix.workspace(name: "a2", parent: "a"),
            Fix.workspace(name: "b"),
        ])
        let rows = buildWorkspaceTree(snap, now: Fix.now)
        XCTAssertEqual(rows.map { $0.name }, ["a", "a1", "a1x", "a2", "b"])
        XCTAssertEqual(rows.map { $0.isLast }, [false, false, true, true, true])
        XCTAssertEqual(rows.map { $0.ancestorContinues },
                       [[], [true], [true, true], [true], []])
    }

    func testLastRootsSubtreeDrawsNoContinuingLane() {
        // a
        // b            (last root)
        // └─ b1        ancestors: [b does NOT continue]
        let snap = Fix.snapshot(workspaces: [
            Fix.workspace(name: "a"),
            Fix.workspace(name: "b"),
            Fix.workspace(name: "b1", parent: "b"),
        ])
        let rows = buildWorkspaceTree(snap, now: Fix.now)
        XCTAssertEqual(rows.map { $0.name }, ["a", "b", "b1"])
        XCTAssertEqual(rows[2].ancestorContinues, [false])
        XCTAssertTrue(rows[2].isLast)
    }

    func testUnknownParentBecomesRoot() {
        let snap = Fix.snapshot(workspaces: [
            Fix.workspace(name: "orphan", parent: "ghost"),
            Fix.workspace(name: "base-kid"),
        ])
        let rows = buildWorkspaceTree(snap, now: Fix.now)
        XCTAssertEqual(rows.map { $0.name }, ["base-kid", "orphan"])
        XCTAssertEqual(rows.map { $0.depth }, [0, 0])
    }

    func testSelfParentBecomesRoot() {
        let snap = Fix.snapshot(workspaces: [Fix.workspace(name: "loner", parent: "loner")])
        let rows = buildWorkspaceTree(snap, now: Fix.now)
        XCTAssertEqual(rows.map { $0.name }, ["loner"])
        XCTAssertEqual(rows.map { $0.depth }, [0])
    }

    func testCycleMembersBecomeRootsAndDescendantsStayAttached() {
        // alpha <-> beta is a 2-cycle; gamma hangs below alpha.
        let snap = Fix.snapshot(workspaces: [
            Fix.workspace(name: "alpha", parent: "beta"),
            Fix.workspace(name: "beta", parent: "alpha"),
            Fix.workspace(name: "gamma", parent: "alpha"),
        ])
        let rows = buildWorkspaceTree(snap, now: Fix.now)
        XCTAssertEqual(rows.map { $0.name }, ["alpha", "gamma", "beta"])
        XCTAssertEqual(rows.map { $0.depth }, [0, 1, 0])
        XCTAssertEqual(Set(rows.map { $0.name }).count, rows.count, "no duplicates")
    }

    func testThreeCycleAllMembersBecomeRoots() {
        let snap = Fix.snapshot(workspaces: [
            Fix.workspace(name: "a", parent: "c"),
            Fix.workspace(name: "b", parent: "a"),
            Fix.workspace(name: "c", parent: "b"),
        ])
        let rows = buildWorkspaceTree(snap, now: Fix.now)
        XCTAssertEqual(rows.map { $0.name }, ["a", "b", "c"])
        XCTAssertEqual(rows.map { $0.depth }, [0, 0, 0])
    }

    func testRowCarriesWorkspaceBadgesAndId() {
        let snap = Fix.snapshot(workspaces: [
            Fix.workspace(name: "w", repos: [Fix.repoState(dirty: 2)]),
        ])
        let rows = buildWorkspaceTree(snap, now: Fix.now)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "w")
        XCTAssertEqual(rows[0].badges.dirtyTotal, 2)
        XCTAssertEqual(rows[0].workspace.umbrellaPath, "/ws/w")
    }

    func testEmptySnapshotYieldsNoRows() {
        XCTAssertTrue(buildWorkspaceTree(Fix.snapshot(workspaces: []), now: Fix.now).isEmpty)
    }
}
