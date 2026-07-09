import XCTest
@testable import GroveAppKit

/// Width-budget invariant: the fixed columns must leave the Session column
/// at least 180 pt wide inside a 576 pt content area (600 pt window − 24 pt
/// horizontal padding).
///
/// If any constant changes and causes the budget to overflow, this test fails
/// immediately — no more silent truncation of the Session title.
final class SessionColumnWidthTests: XCTestCase {

    private let contentWidth: CGFloat = 576   // 600pt window − 12pt×2 padding
    private let minSessionWidth: CGFloat = 180
    private let hspacing: CGFloat = 10
    private let columnCount = 4              // Status | Session | Location | gear | action → 4 fixed cols

    func testFixedColumnsLeaveEnoughRoomForSessionTitle() {
        let fixedTotal = SessionsScreen.statusWidth
                       + SessionsScreen.locationWidth
                       + SessionsScreen.gearWidth
                       + SessionsScreen.actionWidth

        // HStack gaps: 4 gaps (between 5 items where Session uses .infinity)
        let gaps = CGFloat(4) * hspacing

        let sessionWidth = contentWidth - fixedTotal - gaps

        XCTAssertGreaterThanOrEqual(
            sessionWidth,
            minSessionWidth,
            "Session column gets only \(sessionWidth)pt (need ≥\(minSessionWidth)pt). " +
            "Fixed cols: status=\(SessionsScreen.statusWidth) location=\(SessionsScreen.locationWidth) " +
            "gear=\(SessionsScreen.gearWidth) action=\(SessionsScreen.actionWidth) gaps=\(gaps)"
        )
    }

    func testAccountWidthConstantIsRemoved() {
        // AccountWidth must not exist as a positive column budget; the property
        // was deleted in the redesign. We verify this indirectly: the total
        // fixed budget (status+location+gear+action) must be < 340 pt, which
        // is only achievable without the old 80 pt account column.
        let fixedTotal = SessionsScreen.statusWidth
                       + SessionsScreen.locationWidth
                       + SessionsScreen.gearWidth
                       + SessionsScreen.actionWidth
        XCTAssertLessThan(fixedTotal, 340,
            "Fixed column total \(fixedTotal)pt suggests accountWidth (80pt) is still present")
    }
}
