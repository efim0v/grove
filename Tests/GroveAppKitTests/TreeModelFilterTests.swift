import XCTest
import GroveCore
import GroveAppKit

final class TreeModelFilterTests: XCTestCase {

    /// media            (branch feat/media)
    /// ├─ media-upload  (branch feat/media-upload)
    /// └─ media-view    (branch feat/media-view)
    /// payments         (branch hotfix/PAY-12)
    private func rows() -> [WorkspaceTreeRow] {
        let snap = Fix.snapshot(workspaces: [
            Fix.workspace(name: "media",
                          repos: [Fix.repoState(branch: "feat/media")]),
            Fix.workspace(name: "media-upload", parent: "media",
                          repos: [Fix.repoState(branch: "feat/media-upload")]),
            Fix.workspace(name: "media-view", parent: "media",
                          repos: [Fix.repoState(branch: "feat/media-view")]),
            Fix.workspace(name: "payments",
                          repos: [Fix.repoState(branch: "hotfix/PAY-12")]),
        ])
        return buildWorkspaceTree(snap, now: Fix.now)
    }

    func testEmptyAndWhitespaceQueryReturnsAllRowsUnchanged() {
        let all = rows()
        XCTAssertEqual(filterTree(all, query: ""), all)
        XCTAssertEqual(filterTree(all, query: "   "), all)
    }

    func testNameMatchKeepsAncestors() {
        XCTAssertEqual(filterTree(rows(), query: "upload").map { $0.name },
                       ["media", "media-upload"])
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertEqual(filterTree(rows(), query: "UPLOAD").map { $0.name },
                       ["media", "media-upload"])
    }

    func testBranchNameMatchesCaseInsensitively() {
        XCTAssertEqual(filterTree(rows(), query: "pay-12").map { $0.name }, ["payments"])
    }

    func testParentMatchDoesNotDragInNonMatchingChildren() {
        XCTAssertEqual(filterTree(rows(), query: "payments").map { $0.name }, ["payments"])
    }

    func testNoMatchYieldsEmpty() {
        XCTAssertTrue(filterTree(rows(), query: "zzz-not-there").isEmpty)
    }

    func testFilteredRowsKeepOriginalOrderAndDepths() {
        let filtered = filterTree(rows(), query: "media")
        XCTAssertEqual(filtered.map { $0.name }, ["media", "media-upload", "media-view"])
        XCTAssertEqual(filtered.map { $0.depth }, [0, 1, 1])
    }

    func testQueryWithSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(filterTree(rows(), query: "  upload  ").map { $0.name },
                       ["media", "media-upload"])
    }
}
