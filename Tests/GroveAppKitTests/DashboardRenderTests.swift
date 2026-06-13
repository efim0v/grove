import XCTest
import SwiftUI
@testable import GroveAppKit
import GroveCore

/// Drives the LIVE render paths the snapshot scenes skip: Swift Charts marks
/// (BarMark/LineMark/AreaMark), the ProgressBar, and the .globalSettings screen.
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

    func testDashboardColumnRendersLiveChartPaths() {
        let state = SnapshotMode.fixtureState()
        let now = Date()
        let overall = overallDashboard(
            analyticsByAccount: state.usageByAccount,
            snapshotsByAccount: state.snapshotsByAccount,
            aggregateFiveHour: state.aggregateRemaining(window: .fiveHour, now: now),
            aggregateWeekly: state.aggregateRemaining(window: .sevenDay, now: now),
            now: now)
        // isSnapshotRender:false -> the real Chart {} expressions execute.
        render(DashboardColumnView(column: overall, isSnapshotRender: false))
        // And the whole tab (horizontal/vertical ScrollView live path).
        render(DashboardScreen(state: state), height: 900)
    }

    func testDashboardColumnHandlesEmptyData() {
        let empty = RateLimitModel.Aggregate(remaining: 0, total: 0)
        let column = overallDashboard(analyticsByAccount: [:], snapshotsByAccount: [:],
                                      aggregateFiveHour: empty, aggregateWeekly: empty, now: Date())
        // Exercises the "no data" / "not enough captures" / empty-bars branches.
        render(DashboardColumnView(column: column, isSnapshotRender: false))
        render(DashboardColumnView(column: column, isSnapshotRender: true))
    }

    func testGlobalSettingsScreenRenders() {
        let state = SnapshotMode.fixtureState()
        render(GlobalSettingsScreen(state: state).environment(\.isSnapshotRender, true), height: 420)
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
