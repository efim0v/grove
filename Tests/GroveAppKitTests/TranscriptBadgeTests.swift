import XCTest
@testable import GroveAppKit

final class TranscriptBadgeTests: XCTestCase {
    func testBadgeState() {
        XCTAssertEqual(TranscriptBadge.state(liveExists: true,  mirrored: true),  .mirrored)
        XCTAssertEqual(TranscriptBadge.state(liveExists: false, mirrored: true),  .restorable)
        XCTAssertEqual(TranscriptBadge.state(liveExists: true,  mirrored: false), .unmirrored)
    }
}
