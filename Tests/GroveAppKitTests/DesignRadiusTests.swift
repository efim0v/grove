import XCTest
@testable import GroveAppKit

/// Corner system (DesignSystem.swift): fixed radii per chrome level plus the
/// concentric helper used when a ConcentricRectangle cannot resolve (mid-card
/// chips far from any container corner). Pronounced iOS-26 squircle on the gray
/// content cards (panel 17 / card 12.6 / field 10.2) over a Liquid Glass window.
final class DesignRadiusTests: XCTestCase {
    func testChromeLevelsAreConcentricallyOrdered() {
        XCTAssertEqual(DesignRadius.panel, 17)
        XCTAssertEqual(DesignRadius.card, 12.6)
        XCTAssertEqual(DesignRadius.field, 10.2)
        XCTAssertGreaterThan(DesignRadius.panel, DesignRadius.card)
        XCTAssertGreaterThan(DesignRadius.card, DesignRadius.field)
    }

    func testNestedSubtractsTheInset() {
        XCTAssertEqual(DesignRadius.nested(parent: 30, inset: 10), 20)
        XCTAssertEqual(DesignRadius.nested(parent: 22, inset: 4), 18)
        XCTAssertEqual(DesignRadius.nested(parent: DesignRadius.card, inset: 1), DesignRadius.card - 1)
    }

    func testNestedNeverDropsBelowFourPoints() {
        XCTAssertEqual(DesignRadius.nested(parent: 22, inset: 20), 4)
        XCTAssertEqual(DesignRadius.nested(parent: 14, inset: 24), 4)   // never negative
        XCTAssertEqual(DesignRadius.nested(parent: 4, inset: 0), 4)
    }
}
