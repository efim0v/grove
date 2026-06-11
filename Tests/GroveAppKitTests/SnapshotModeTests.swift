import XCTest
@testable import GroveAppKit
import GroveCore

final class SnapshotModeTests: XCTestCase {
    // MARK: - argument parsing (pure)

    func testParseReturnsNilWithoutFlag() {
        XCTAssertNil(SnapshotMode.parseSnapshotDir(from: ["GroveApp"]))
        XCTAssertNil(SnapshotMode.parseSnapshotDir(from: []))
    }

    func testParseReturnsDirectoryAfterFlag() {
        XCTAssertEqual(SnapshotMode.parseSnapshotDir(from: ["GroveApp", "--snapshot", "/tmp/out"]),
                       "/tmp/out")
    }

    func testParseReturnsNilWhenFlagIsLastArgument() {
        XCTAssertNil(SnapshotMode.parseSnapshotDir(from: ["GroveApp", "--snapshot"]))
    }

    // MARK: - scenes

    func testSixScenesWithContractFileNames() {
        XCTAssertEqual(SnapshotMode.SnapshotScene.allCases.map(\.fileName),
                       ["root-workspaces.png", "workspaces-expanded.png", "create-sheet.png",
                        "graph.png", "accounts.png", "settings.png"])
    }

    // MARK: - rich fixture (Task 18)

    @MainActor
    func testFixtureHasFourWorkspacesIncludingOneStackedChild() {
        let snapshot = SnapshotMode.fixtureState().selectedSnapshot
        XCTAssertEqual(snapshot?.workspaces.map(\.name),
                       ["folders-followup", "live-tier-redis", "media-pipeline", "media-upload"])
        let stacked = snapshot?.workspaces.filter { $0.parentName != nil }
        XCTAssertEqual(stacked?.count, 1)
        XCTAssertEqual(stacked?.first?.name, "media-upload")
        XCTAssertEqual(stacked?.first?.parentName, "media-pipeline")
        // Stacked meta is relative to the parent branch, like the real scanner.
        XCTAssertEqual(stacked?.first?.repos.first?.meta?.baseBranch, "feat/media-pipeline")
    }

    @MainActor
    func testFixtureCoversAllFourAgeBuckets() {
        let snapshot = SnapshotMode.fixtureState().selectedSnapshot!
        let now = Date()
        let buckets = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map {
            ($0.name, badges(for: $0, now: now).ageBucket)
        })
        XCTAssertEqual(buckets["media-upload"], .fresh)        // 2d
        XCTAssertEqual(buckets["media-pipeline"], .aging)      // 12d
        XCTAssertEqual(buckets["folders-followup"], .stale)    // 24d
        XCTAssertEqual(buckets["live-tier-redis"], .unknown)   // meta nil
    }

    @MainActor
    func testFixtureClaudeMixes() {
        let snapshot = SnapshotMode.fixtureState().selectedSnapshot!
        let now = Date()
        let byName = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map {
            ($0.name, badges(for: $0, now: now))
        })
        XCTAssertEqual(byName["media-pipeline"]?.busyCount, 1)
        XCTAssertEqual(byName["media-pipeline"]?.resumableCount, 0)
        XCTAssertEqual(byName["media-pipeline"]?.dirtyTotal, 12)
        XCTAssertEqual(byName["media-upload"]?.waitingCount, 1)
        XCTAssertEqual(byName["media-upload"]?.resumableCount, 1)
        XCTAssertEqual(byName["folders-followup"]?.resumableCount, 2)
        XCTAssertEqual(byName["folders-followup"]?.dirtyTotal, 0)
        XCTAssertEqual(byName["live-tier-redis"]?.busyCount, 0)
    }

    @MainActor
    func testFixtureHasTwoLooseWorktreesAndCmuxMapping() {
        let snapshot = SnapshotMode.fixtureState().selectedSnapshot!
        XCTAssertEqual(snapshot.loose.count, 2)
        XCTAssertEqual(snapshot.loose.first?.meta?.ahead, 9)
        XCTAssertEqual(snapshot.loose.first?.meta?.behind, 3)
        XCTAssertNil(snapshot.loose.last?.meta)                // degraded loose scan
        let mp = snapshot.workspaces.first { $0.name == "media-pipeline" }
        XCTAssertEqual(mp?.cmuxWorkspaces.first?.id, "ws-101")
    }

    @MainActor
    func testFixtureGraphNodesSpanMultipleLanes() {
        let state = SnapshotMode.fixtureState()
        XCTAssertEqual(state.graphRepoPath, "/Users/demo/Desktop/acme.shop/acme_client")
        XCTAssertFalse(state.graphNodes.isEmpty)
        XCTAssertGreaterThanOrEqual(Set(state.graphNodes.map(\.lane)).count, 3)
        XCTAssertTrue(state.graphNodes.contains { $0.parents.count == 2 })   // a merge
        XCTAssertTrue(state.graphNodes.contains { $0.refs.contains("tag: v0.4.0") })
    }

    @MainActor
    func testFixtureGraphLanesMatchLayoutLanes() {
        let nodes = SnapshotMode.fixtureGraphNodes(now: Date())
        let raw = nodes.map {
            RawCommit(hash: $0.hash, parents: $0.parents, author: $0.author,
                      date: $0.date, refs: $0.refs, subject: $0.subject)
        }
        XCTAssertEqual(layoutLanes(raw).map(\.lane), nodes.map(\.lane))
    }

    func testFixtureIdentityOnlyForDefaultAccount() {
        let identity = SnapshotMode.fixtureIdentity(AccountConfig(name: "default", configDir: "~/.claude"))
        XCTAssertEqual(identity?.email, "artem@example.com")
        XCTAssertEqual(identity?.tier, "max_20x")
        XCTAssertNil(SnapshotMode.fixtureIdentity(AccountConfig(name: "work",
                                                                configDir: "~/.claude-accounts/work")))
    }

    @MainActor
    func testFixturePrefillsBranchesForEveryRepoIncludingResolvedDefaults() {
        let state = SnapshotMode.fixtureState()
        let snapshot = state.selectedSnapshot!
        XCTAssertEqual(Set(state.branchesByRepo.keys), Set(snapshot.repos.map(\.path)))
        // The create-sheet picker default per repo must be a real option so
        // the PNGs never show an empty/ghost selection.
        for repo in snapshot.repos {
            let resolved = startPointCaption(repo: repo, forkFrom: nil, base: nil,
                                             snapshot: snapshot)
            XCTAssertEqual(state.branchesByRepo[repo.path]?.contains(resolved), true,
                           "\(repo.dirName): \(resolved) missing from fixture branches")
        }
        // Per-project default account drives settings.png + New Claude clicks.
        XCTAssertEqual(state.selectedProject?.defaultAccount, "work")
        XCTAssertEqual(state.defaultLaunchAccount?.name, "work")
    }

    @MainActor
    func testFixtureStateTouchesNoRealConfig() {
        let state = SnapshotMode.fixtureState()
        XCTAssertNil(state.configIssue)               // nonexistent temp path -> clean defaults
        XCTAssertEqual(state.selectedProject?.name, "acme.shop")
        XCTAssertEqual(state.config.accounts.map(\.name), ["default", "work"])
    }
}
