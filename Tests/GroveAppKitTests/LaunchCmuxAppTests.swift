import XCTest
import GroveCore
@testable import GroveAppKit

@MainActor
final class LaunchCmuxAppTests: XCTestCase {
    func testLaunchCmuxAppClearsCmuxErrorWhenPingSucceeds() async throws {
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let configURL = try FixtureLite.tempDir("launch-cmux")
            .appendingPathComponent("config.json")
        let state = AppState(configStore: ConfigStore(url: configURL))
        state.cmuxOverride = stubbedCmux(runner)
        state.actionError = "cmux unavailable: cmux did not answer ping within 10s"

        await state.launchCmuxApp()

        XCTAssertNil(state.actionError, "successful ensureRunning clears the banner")
        XCTAssertEqual(runner.calls(startingWith: "ping").count, 1)
        XCTAssertTrue(runner.calls.filter { $0.executable == "/usr/bin/open" }.isEmpty,
                      "cmux already answers ping -> no `open -b` needed")
    }
}
