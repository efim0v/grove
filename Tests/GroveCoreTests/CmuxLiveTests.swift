import XCTest
@testable import GroveCore

final class CmuxLiveTests: XCTestCase {
    /// Run manually: GROVE_LIVE_CMUX=1 swift test --filter CmuxLiveTests
    func testLivePingAndList() async throws {
        guard ProcessInfo.processInfo.environment["GROVE_LIVE_CMUX"] == "1" else {
            throw XCTSkip("set GROVE_LIVE_CMUX=1 to run against the real cmux")
        }
        let cmux = CmuxService()
        guard await cmux.ping() else { throw XCTSkip("cmux app is not running") }
        let list = try await cmux.listWorkspaces()
        XCTAssertFalse(list.isEmpty, "expected at least one live cmux workspace")
        let map = cmux.claudeSessionWorkspaceMap()
        // Map may legitimately be empty (no hooked sessions), but parsing must not crash.
        _ = map
    }
}
