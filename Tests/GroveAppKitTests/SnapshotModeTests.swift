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

    // MARK: - fixture skeleton (Task 15: exactly one workspace)

    @MainActor
    func testFixtureStateHasOneProjectAndOneWorkspace() {
        let state = SnapshotMode.fixtureState()
        XCTAssertEqual(state.config.projects.count, 1)
        XCTAssertNotNil(state.selectedProjectID)
        let snapshot = state.selectedSnapshot
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.workspaces.count, 1)
        XCTAssertEqual(snapshot?.workspaces.first?.name, "media-pipeline")
        XCTAssertEqual(snapshot?.workspaces.first?.liveProcesses.first?.status, "busy")
    }

    @MainActor
    func testFixtureStateTouchesNoRealConfig() {
        let state = SnapshotMode.fixtureState()
        XCTAssertNil(state.configIssue)               // nonexistent temp path -> clean defaults
        XCTAssertEqual(state.selectedProject?.name, "acme.shop")
    }
}
