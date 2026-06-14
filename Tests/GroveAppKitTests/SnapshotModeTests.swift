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

    // MARK: - end-to-end rendering (exercises every routed view body)

    /// Renders all scenes through the real ImageRenderer pipeline and asserts each
    /// PNG is produced and non-trivial. This drives every routed screen's body
    /// (RootShell/ProjectsTab/DashboardScreen/ProjectScreen tabs/AccountsScreen…)
    /// so a layout that crashes or renders blank is caught in CI, not by eye.
    @MainActor
    func testAllScenesRenderToNonEmptyPNGs() throws {
        let dir = try FixtureLite.tempDir("snapshot-render")
        let count = try SnapshotMode.renderAll(into: dir)
        XCTAssertEqual(count, SnapshotMode.SnapshotScene.allCases.count)
        for scene in SnapshotMode.SnapshotScene.allCases {
            let path = dir.appendingPathComponent(scene.fileName).path
            let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            XCTAssertGreaterThan(size, 2_000, "\(scene.fileName) rendered too small/empty")
        }
    }

    // MARK: - scenes

    func testScenesHaveContractFileNames() {
        XCTAssertEqual(SnapshotMode.SnapshotScene.allCases.map(\.fileName),
                       ["projects.png", "charts.png", "root-workspaces.png", "workspaces-expanded.png",
                        "create-sheet.png", "graph.png", "stats.png", "sessions.png", "accounts.png",
                        "accounts-usage.png", "settings.png", "error-banner.png"])
    }

    /// Every scene is RootView with a ROUTE (the panel is a state machine of
    /// full-screen views, no overlays); the fixture project anchors the
    /// project-scoped routes.
    @MainActor
    func testScenesConfigureTheRoutePerScreen() throws {
        func state(_ scene: SnapshotMode.SnapshotScene) -> AppState {
            SnapshotMode.configuredState(for: scene)
        }
        let projectID = try XCTUnwrap(state(.projects).selectedProjectID)

        XCTAssertEqual(state(.projects).route, .projects)
        XCTAssertEqual(state(.charts).route, .projects)   // charts side window (no tab)
        XCTAssertEqual(state(.rootWorkspaces).route, .project(projectID))
        XCTAssertEqual(state(.workspacesExpanded).route, .project(projectID))
        XCTAssertEqual(state(.graph).route, .project(projectID))
        XCTAssertEqual(state(.graph).selectedTab, .graph)
        XCTAssertEqual(state(.stats).route, .project(projectID))
        XCTAssertEqual(state(.stats).selectedTab, .stats)
        XCTAssertEqual(state(.sessions).route, .project(projectID))
        XCTAssertEqual(state(.sessions).selectedTab, .sessions)
        XCTAssertEqual(state(.accounts).route, .accounts)
        // accounts-usage routes to .accounts too, but the fixture carries the
        // usage data so the AccountsScreen renders bars/cards/tables.
        let usage = state(.accountsUsage)
        XCTAssertEqual(usage.route, .accounts)
        XCTAssertFalse(usage.usageByAccount.isEmpty, "accounts-usage must carry usage analytics")
        XCTAssertFalse(usage.snapshotsByAccount.isEmpty, "accounts-usage must carry capture snapshots")
        XCTAssertEqual(state(.settings).route, .projectSettings(projectID))

        let create = state(.createSheet)
        XCTAssertEqual(create.route, .createWorkspace(projectID))
        XCTAssertEqual(create.createPrefill?.name, "checkout-flow")

        // error-banner pins the RootView banner styling: actionError set, and
        // the message mentions cmux so the "Launch cmux" affordance renders.
        let banner = state(.errorBanner)
        XCTAssertEqual(banner.route, .projects)
        XCTAssertEqual(banner.actionError?.localizedCaseInsensitiveContains("cmux"), true)
        // No other scene shows the banner.
        for scene in SnapshotMode.SnapshotScene.allCases where scene != .errorBanner {
            XCTAssertNil(state(scene).actionError, "\(scene) must not set actionError")
        }
    }

    /// Canvas sizes mirror RootView's adaptive per-route panel frames.
    func testSceneSizesFollowTheAdaptivePanelFrames() {
        XCTAssertEqual(SnapshotMode.SnapshotScene.projects.size, CGSize(width: 460, height: 520))
        XCTAssertEqual(SnapshotMode.SnapshotScene.charts.size, CGSize(width: 290, height: 800))
        XCTAssertEqual(SnapshotMode.SnapshotScene.rootWorkspaces.size, CGSize(width: 760, height: 540))
        XCTAssertEqual(SnapshotMode.SnapshotScene.workspacesExpanded.size, CGSize(width: 760, height: 540))
        XCTAssertEqual(SnapshotMode.SnapshotScene.graph.size, CGSize(width: 760, height: 540))
        XCTAssertEqual(SnapshotMode.SnapshotScene.stats.size, CGSize(width: 760, height: 540))
        XCTAssertEqual(SnapshotMode.SnapshotScene.sessions.size, CGSize(width: 760, height: 540))
        XCTAssertEqual(SnapshotMode.SnapshotScene.createSheet.size, CGSize(width: 540, height: 560))
        XCTAssertEqual(SnapshotMode.SnapshotScene.accounts.size, CGSize(width: 560, height: 480))
        // accounts-usage shares the accounts adaptive panel frame.
        XCTAssertEqual(SnapshotMode.SnapshotScene.accountsUsage.size, CGSize(width: 560, height: 480))
        XCTAssertEqual(SnapshotMode.SnapshotScene.settings.size, CGSize(width: 560, height: 560))
        // projects frame + vertical allowance for the banner stacked above it.
        XCTAssertEqual(SnapshotMode.SnapshotScene.errorBanner.size, CGSize(width: 460, height: 584))
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

    /// Locks what sessions.png must render: a busy live row mapped to Go (its
    /// cwd is listed by a cmux workspace), a waiting live row, resumables, and
    /// both accounts represented (spec §5 variety).
    @MainActor
    func testFixtureSessionRowsCoverStatusAndActionVariety() {
        let snapshot = SnapshotMode.fixtureState().selectedSnapshot!
        let rows = buildSessionRows(snapshot: snapshot, cmuxMap: [:])
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionId, $0) })

        // busy live, mapped to Go via the media-pipeline cmux workspace cwd,
        // with a runtime (startedAt set in the fixture).
        XCTAssertEqual(byId["s-mp-1"]?.liveStatus, .busy)
        XCTAssertEqual(byId["s-mp-1"]?.action, .go)
        XCTAssertNotNil(byId["s-mp-1"]?.startedAt)
        XCTAssertEqual(byId["s-mp-1"]?.location, "media-pipeline")
        XCTAssertEqual(byId["s-mp-1"]?.accountName, "default")

        // waiting live, no cmux workspace -> Resume, also has a runtime.
        XCTAssertEqual(byId["s-mu-1"]?.liveStatus, .waiting)
        XCTAssertEqual(byId["s-mu-1"]?.action, .resume)
        XCTAssertNotNil(byId["s-mu-1"]?.startedAt)
        XCTAssertEqual(byId["s-mu-1"]?.accountName, "work")

        // resumables (no live process).
        XCTAssertNil(byId["s-mu-2"]?.liveStatus)
        XCTAssertEqual(byId["s-mu-2"]?.action, .resume)
        XCTAssertNil(byId["s-ff-1"]?.liveStatus)

        // loose worktree session location derives from the worktree leaf.
        XCTAssertEqual(byId["s-gc-1"]?.location, "group-chats")

        // Both accounts present in the table.
        XCTAssertEqual(Set(rows.map(\.accountName)), ["default", "work"])
        // Live first (busy before waiting), resumables after.
        XCTAssertEqual(Array(rows.prefix(2).map(\.sessionId)), ["s-mp-1", "s-mu-1"])
        XCTAssertTrue(rows.dropFirst(2).allSatisfy { $0.liveStatus == nil })
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
