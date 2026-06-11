import XCTest
@testable import GroveCore

final class CmuxProbeTests: XCTestCase {
    func testParseOutFileExtractsValueAfterFlag() {
        XCTAssertEqual(
            CmuxProbe.parseOutFile(from: ["Grove", "--cmux-probe", "/tmp/report.txt"]),
            "/tmp/report.txt")
    }

    func testParseOutFileNilWhenFlagAbsentOrLast() {
        XCTAssertNil(CmuxProbe.parseOutFile(from: ["Grove"]))
        XCTAssertNil(CmuxProbe.parseOutFile(from: ["Grove", "--cmux-probe"]))
        XCTAssertNil(CmuxProbe.parseOutFile(from: ["Grove", "--snapshot", "/tmp/x"]))
    }
}
