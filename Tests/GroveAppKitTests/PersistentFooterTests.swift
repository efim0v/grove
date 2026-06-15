import XCTest
import SwiftUI
@testable import GroveAppKit
import GroveCore

/// Issue 1: the projects-column footer (Accounts · settings · refresh · charts
/// toggle · version · Quit) is SHARED chrome — RootView pins it below BOTH the
/// project LIST (.projects) and the per-project tabs (.project) so it no longer
/// disappears when the user drills into a project. The deeper scoped routes keep
/// their own back navigation and DON'T show it.
@MainActor
final class PersistentFooterTests: XCTestCase {
    private let projectID = UUID()

    func testFooterShownOnProjectsAndProjectRoutes() {
        XCTAssertTrue(RootView.showsFooter(for: .projects))
        XCTAssertTrue(RootView.showsFooter(for: .project(projectID)))
    }

    func testFooterHiddenOnDeepScopedRoutes() {
        XCTAssertFalse(RootView.showsFooter(for: .accounts))
        XCTAssertFalse(RootView.showsFooter(for: .globalSettings))
        XCTAssertFalse(RootView.showsFooter(for: .projectSettings(projectID)))
        XCTAssertFalse(RootView.showsFooter(for: .statsSettings(projectID)))
        XCTAssertFalse(RootView.showsFooter(for: .createWorkspace(projectID)))
    }

    /// The hoisted footer must render through the real pipeline on a project tab
    /// (where it previously didn't exist) without crashing or going blank.
    func testProjectTabRoutesRenderWithFooter() {
        for tab in MainTab.allCases {
            let s = SnapshotMode.fixtureState()
            s.selectedTab = tab
            s.route = .project(s.selectedProjectID!)
            let view = RootView(state: s)
                .frame(width: 600, height: 540)
                .environment(\.colorScheme, .dark)
                .environment(\.isSnapshotRender, true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            XCTAssertNotNil(renderer.cgImage, "\(tab) project route failed to render")
        }
    }
}
