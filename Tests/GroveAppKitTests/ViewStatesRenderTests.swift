import XCTest
import SwiftUI
@testable import GroveAppKit
import GroveCore

/// Renders RootView in states the fixed 11 snapshot scenes don't cover (search
/// active, empty/scanning, non-cmux error banner, charts with no accounts), so
/// the per-screen branch bodies execute. Forcing cgImage evaluates each body.
@MainActor
final class ViewStatesRenderTests: XCTestCase {
    private func render(_ state: AppState, _ size: CGSize) {
        let view = RootView(state: state)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        _ = renderer.cgImage
    }

    private let projectSize = CGSize(width: 600, height: 540)

    func testSessionsSearchNoMatchAndEmptyScanning() {
        let s = SnapshotMode.fixtureState()
        s.selectedTab = .sessions
        s.route = .project(s.selectedProjectID!)
        s.searchQuery = "zzz-no-match"
        render(s, projectSize)

        let s2 = SnapshotMode.fixtureState()
        s2.selectedTab = .sessions
        s2.route = .project(s2.selectedProjectID!)
        s2.snapshots = [:]              // no snapshot -> "scan this project" empty state
        s2.isScanning = true
        render(s2, projectSize)
    }

    func testWorkspacesSearchAndGraphTab() {
        let s = SnapshotMode.fixtureState()
        s.route = .project(s.selectedProjectID!)
        s.selectedTab = .workspaces
        s.searchQuery = "media"
        render(s, projectSize)

        s.selectedTab = .graph
        render(s, projectSize)
    }

    /// Exercises the merged window root (the projects section under the window's
    /// glass). Forcing cgImage catches a crashing/blank body.
    func testMergedRootRenders() {
        let state = SnapshotMode.fixtureState()
        let view = MergedRootView(state: state)
            .frame(width: 460, height: 520)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        _ = renderer.cgImage
    }

    func testNonCmuxErrorBannerBranch() {
        let s = SnapshotMode.fixtureState()
        s.actionError = "config.json is unreadable"   // no "cmux" -> no Launch cmux button
        render(s, CGSize(width: 460, height: 584))
    }

    func testProjectsTabWhileScanning() {
        let s = SnapshotMode.fixtureState()
        s.isScanning = true
        render(s, CGSize(width: 460, height: 520))
    }
}
