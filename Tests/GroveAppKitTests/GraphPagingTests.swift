import XCTest
import GroveCore
@testable import GroveAppKit

@MainActor
final class GraphPagingTests: XCTestCase {
    private var repo: URL!
    private var configURL: URL!

    /// 5-commit linear repo; subjects newest-first: c4, c3, c2, c1, base.
    override func setUp() async throws {
        let root = try FixtureLite.tempDir("graph-paging")
        repo = try FixtureLite.makeRepo(in: root, name: "g")
        for n in 1...4 {
            try FixtureLite.commit(repo: repo, file: "f\(n).txt", content: "\(n)\n", message: "c\(n)")
        }
        configURL = root.appendingPathComponent("config.json")
    }

    private func makeState(pageSize: Int) -> AppState {
        let state = AppState(configStore: ConfigStore(url: configURL))
        state.cmuxOverride = stubbedCmux()
        state.graphPageSize = pageSize
        return state
    }

    func testLoadGraphFullPageSetsCanLoadMore() async {
        let state = makeState(pageSize: 2)
        await state.loadGraph(repoPath: repo.path)
        XCTAssertEqual(state.graphNodes.map(\.subject), ["c4", "c3"])
        XCTAssertTrue(state.graphCanLoadMore)
    }

    func testLoadMoreAppendsUntilShortPage() async {
        let state = makeState(pageSize: 2)
        await state.loadGraph(repoPath: repo.path)

        await state.loadMoreGraph()
        XCTAssertEqual(state.graphNodes.map(\.subject), ["c4", "c3", "c2", "c1"])
        XCTAssertTrue(state.graphCanLoadMore)

        await state.loadMoreGraph()
        XCTAssertEqual(state.graphNodes.map(\.subject), ["c4", "c3", "c2", "c1", "base"])
        XCTAssertFalse(state.graphCanLoadMore, "short page (1 < 2) ends paging")

        await state.loadMoreGraph()   // exhausted -> no-op
        XCTAssertEqual(state.graphNodes.count, 5)
        XCTAssertNil(state.actionError)
    }

    func testLoadMoreDropsDuplicatesWhenNewCommitsShiftPaging() async throws {
        let state = makeState(pageSize: 2)
        await state.loadGraph(repoPath: repo.path)
        XCTAssertEqual(state.graphNodes.map(\.subject), ["c4", "c3"])

        // A commit created between page loads (Grove's normal case: agents
        // committing continuously) shifts `git log --all --topo-order`, so
        // skip-based paging now returns [c3, c2] — c3 is already loaded and
        // must be dropped, never appended (duplicate hashes are ForEach
        // identities and would trap GraphLanesCanvas's row dictionary).
        try FixtureLite.commit(repo: repo, file: "f5.txt", content: "5\n", message: "c5")

        await state.loadMoreGraph()
        XCTAssertEqual(state.graphNodes.map(\.subject), ["c4", "c3", "c2"])
        XCTAssertEqual(Set(state.graphNodes.map(\.hash)).count, state.graphNodes.count,
                       "graphNodes hashes must stay unique")
        XCTAssertTrue(state.graphCanLoadMore, "raw page was full — keep paging")
        XCTAssertNil(state.actionError)
    }

    func testShortFirstPageDisablesLoadMore() async {
        let state = makeState(pageSize: 300)
        await state.loadGraph(repoPath: repo.path)
        XCTAssertEqual(state.graphNodes.count, 5)
        XCTAssertFalse(state.graphCanLoadMore)
    }

    func testLoadGraphFailureResetsPagingFlag() async {
        let state = makeState(pageSize: 2)
        await state.loadGraph(repoPath: repo.path)
        XCTAssertTrue(state.graphCanLoadMore)

        await state.loadGraph(repoPath: "/nonexistent/not-a-repo")
        XCTAssertTrue(state.graphNodes.isEmpty)
        XCTAssertFalse(state.graphCanLoadMore)
        XCTAssertNotNil(state.actionError)
    }
}
