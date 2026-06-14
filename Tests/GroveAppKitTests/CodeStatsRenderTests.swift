import XCTest
import SwiftUI
@testable import GroveAppKit
import GroveCore

/// Renders the Stats tab (Stage 5) in both the offscreen snapshot path (the manual,
/// non-Charts stacked-bar fallback) and the live path (the hand-drawn, horizontally-
/// scrollable cumulative codebase-size strip — a `ScrollView` of per-day stacked-by-repo
/// bars with a `ScrollViewReader` and per-bar tap gesture; no Swift Charts), and asserts
/// the snapshot scene produces a NON-BLANK image — content, not just an empty backdrop.
/// Mirrors DashboardRenderTests / ViewStatesRenderTests.
@MainActor
final class CodeStatsRenderTests: XCTestCase {
    private let projectSize = CGSize(width: 600, height: 540)

    /// True when not every pixel in the image is the same color — a render that
    /// drew real content over the backdrop. (A blank/flat render is uniform.)
    private func isNonBlank(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return false }
        let length = CFDataGetLength(data)
        guard length >= 8 else { return false }
        let first0 = ptr[0], first1 = ptr[1], first2 = ptr[2], first3 = ptr[3]
        var i = 4
        while i + 3 < length {
            if ptr[i] != first0 || ptr[i + 1] != first1
                || ptr[i + 2] != first2 || ptr[i + 3] != first3 {
                return true
            }
            i += 4
        }
        return false
    }

    /// The offscreen snapshot scene (manual growth fallback) renders real content.
    func testStatsSceneRendersNonBlank() {
        let state = SnapshotMode.configuredState(for: .stats)
        // Sanity: the fixture seeded the data the snapshot path relies on.
        let id = state.selectedProjectID!
        XCTAssertNotNil(state.codeStats[id])
        XCTAssertGreaterThanOrEqual((state.codeStatsHistory[id] ?? []).count, 2)

        let view = RootView(state: state)
            .frame(width: projectSize.width, height: projectSize.height)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = renderer.cgImage
        XCTAssertNotNil(image, "stats scene produced no image")
        XCTAssertTrue(isNonBlank(image!), "stats scene rendered blank (no content)")
    }

    /// The LIVE path (isSnapshotRender=false) evaluates the horizontally-scrollable
    /// cumulative stacked-by-repo strip (the per-day ScrollView, its ScrollViewReader,
    /// and the per-bar tap gesture) and the period segmented control — a crash or broken
    /// expression is caught even though offscreen ScrollView pixels are blank.
    func testStatsScreenLiveChartBranch() {
        let state = SnapshotMode.fixtureState()
        state.selectedTab = .stats
        state.route = .project(state.selectedProjectID!)
        let view = CodeStatsScreen(state: state)
            .frame(width: projectSize.width, height: projectSize.height)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotRender, false)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        _ = renderer.cgImage   // forces body eval, incl. the live churn-scroller strip
    }

    /// The per-repo blocks render: the fixture seeds two repos, so the snapshot
    /// path must draw the "Repositories" card without crashing.
    func testStatsScreenRepoBlocksRender() {
        let state = SnapshotMode.configuredState(for: .stats)
        let id = state.selectedProjectID!
        // Sanity: the fixture seeded the per-repo breakdown the blocks render from.
        XCTAssertFalse((state.repoStats[id] ?? []).isEmpty)

        let view = RootView(state: state)
            .frame(width: projectSize.width, height: projectSize.height)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = renderer.cgImage
        XCTAssertNotNil(image, "stats scene with repo blocks produced no image")
        XCTAssertTrue(isNonBlank(image!), "stats scene with repo blocks rendered blank")
    }

    /// The new stats-settings page (directory+file exclusion tree) renders real
    /// content offscreen — it builds purely from the seeded per-file list, so the
    /// flat expanded fallback (snapshot path) draws folder + file rows.
    func testStatsSettingsSceneRendersNonBlank() {
        let state = SnapshotMode.configuredState(for: .statsSettings)
        let id = state.selectedProjectID!
        // Sanity: the fixture seeded the per-file list the tree builds from, and one
        // excluded folder so the dimmed/disabled state participates.
        XCTAssertFalse((state.statsFiles[id] ?? []).isEmpty)
        XCTAssertFalse(state.selectedProject?.statsIgnoredFolders.isEmpty ?? true)

        let view = RootView(state: state)
            .frame(width: 560, height: 560)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = renderer.cgImage
        XCTAssertNotNil(image, "stats-settings scene produced no image")
        XCTAssertTrue(isNonBlank(image!), "stats-settings scene rendered blank (no content)")
    }

    /// The LIVE path (isSnapshotRender=false) evaluates the nested DisclosureGroup
    /// recursion + the folder-exclude checkbox bindings — a crash in the recursive
    /// node view or binding is caught even though offscreen pixels stay blank.
    func testStatsSettingsLiveDisclosureBranch() {
        let state = SnapshotMode.fixtureState()
        let id = state.selectedProjectID!
        state.route = .statsSettings(id)
        let view = StatsSettingsScreen(state: state, projectID: id)
            .frame(width: 560, height: 560)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotRender, false)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        _ = renderer.cgImage   // forces body eval, incl. the recursive DisclosureGroup
    }

    /// Empty (no stats, not scanning) and scanning states render without crashing.
    func testStatsScreenEmptyAndScanningStates() {
        let empty = AppState(configStore: ConfigStore(
            url: URL(fileURLWithPath: NSTemporaryDirectory() + "grove-stats-empty-\(UUID().uuidString).json")))
        empty.addProject(at: "/Users/demo/Desktop/nothing")
        empty.selectedTab = .stats
        render(empty)

        empty.isStatsScanning = true
        render(empty)
    }

    private func render(_ state: AppState) {
        let view = CodeStatsScreen(state: state)
            .frame(width: projectSize.width, height: projectSize.height)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        _ = renderer.cgImage
    }
}
