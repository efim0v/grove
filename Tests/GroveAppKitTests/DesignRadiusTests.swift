import XCTest
@testable import GroveAppKit

/// Corner system (DesignSystem.swift): fixed radii per chrome level plus the
/// concentric helper used when a ConcentricRectangle cannot resolve (mid-card
/// chips far from any container corner). Scaled back to standard macOS rounding
/// (panel 16 / card 12 / field 8) — the earlier 26/22/14 read as too round.
final class DesignRadiusTests: XCTestCase {
    func testChromeLevelsAreConcentricallyOrdered() {
        XCTAssertEqual(DesignRadius.panel, 16)
        XCTAssertEqual(DesignRadius.card, 12)
        XCTAssertEqual(DesignRadius.field, 8)
        XCTAssertGreaterThan(DesignRadius.panel, DesignRadius.card)
        XCTAssertGreaterThan(DesignRadius.card, DesignRadius.field)
    }

    func testNestedSubtractsTheInset() {
        XCTAssertEqual(DesignRadius.nested(parent: 30, inset: 10), 20)
        XCTAssertEqual(DesignRadius.nested(parent: 22, inset: 4), 18)
        XCTAssertEqual(DesignRadius.nested(parent: DesignRadius.card, inset: 2), DesignRadius.card - 2)
    }

    func testNestedNeverDropsBelowEightPoints() {
        XCTAssertEqual(DesignRadius.nested(parent: 22, inset: 16), 8)
        XCTAssertEqual(DesignRadius.nested(parent: 14, inset: 24), 8)   // never negative
        XCTAssertEqual(DesignRadius.nested(parent: 8, inset: 0), 8)
    }
}
