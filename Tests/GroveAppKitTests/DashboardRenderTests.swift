import XCTest
import SwiftUI
@testable import GroveAppKit
import GroveCore

/// Drives the LIVE render paths the snapshot scenes skip: real controls across every
/// routed screen and the .globalSettings screen.
/// Forcing `ImageRenderer.cgImage` evaluates every body, so a crash or a broken
/// chart expression is caught in CI even though the offscreen pixels are blank.
@MainActor
final class DashboardRenderTests: XCTestCase {
    private func render<V: View>(_ view: V, height: CGFloat = 1_400) {
        let renderer = ImageRenderer(content:
            view.frame(width: 320, height: height).environment(\.colorScheme, .dark))
        renderer.scale = 1
        _ = renderer.cgImage   // forces body evaluation, incl. the live Chart code
    }

    /// Renders every scene with isSnapshotRender=FALSE so the LIVE branches the
    /// snapshot pipeline skips execute — real Picker/Menu/TextField/Swift Charts
    /// and the .glassEffect chrome across every routed screen. ImageRenderer draws
    /// glass/AppKit controls blank offscreen, but the bodies still evaluate, so a
    /// broken live-branch expression is caught.
    func testAllScenesRenderLiveBranches() {
        for scene in SnapshotMode.SnapshotScene.allCases {
            let state = SnapshotMode.configuredState(for: scene)
            let size = scene.size
            let view = RootView(state: state)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
                .environment(\.isSnapshotRender, false)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            _ = renderer.cgImage
        }
    }

    func testGlobalSettingsScreenRenders() {
        let state = SnapshotMode.fixtureState()
        render(GlobalSettingsScreen(state: state).environment(\.isSnapshotRender, true), height: 420)
    }

    /// Live branch (isSnapshotRender=false) so the real segmented substrate Picker
    /// in the new "Window substrate" section is exercised, not just its snapshot
    /// lookalike — guards against a crash/regression in that branch.
    func testGlobalSettingsScreenRendersLiveBranch() {
        let state = SnapshotMode.fixtureState()
        render(GlobalSettingsScreen(state: state).environment(\.isSnapshotRender, false), height: 420)
    }

    func testProjectsTabEmptyAndPopulatedStates() {
        let populated = SnapshotMode.fixtureState()
        render(ProjectsTab(state: populated).environment(\.isSnapshotRender, true), height: 520)
        // No-projects empty state.
        let empty = AppState(configStore: ConfigStore(
            url: URL(fileURLWithPath: NSTemporaryDirectory() + "grove-empty-\(UUID().uuidString).json")))
        render(ProjectsTab(state: empty).environment(\.isSnapshotRender, true), height: 520)
    }
}
