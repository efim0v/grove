import XCTest
import GroveCore

final class ScaffoldTests: XCTestCase {
    func testVersionConstant() {
        XCTAssertEqual(GroveVersion.current, "0.1.0")
    }
}
