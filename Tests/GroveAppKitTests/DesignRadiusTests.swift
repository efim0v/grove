import XCTest
@testable import GroveAppKit

/// Corner system (DesignSystem.swift): fixed radii per chrome level plus the
/// concentric helper used when a ConcentricRectangle cannot resolve (mid-card
/// chips far from any container corner). Restrained macOS rounding, 15% softer
/// than the 10/6/5 baseline (panel 11.5 / card 6.9 / field 5.75) — earlier
/// 26/22/14 then 16/12/8 read too round.
final class DesignRadiusTests: XCTestCase {
    func testChromeLevelsAreConcentricallyOrdered() {
        XCTAssertEqual(DesignRadius.panel, 11.5)
        XCTAssertEqual(DesignRadius.card, 6.9)
        XCTAssertEqual(DesignRadius.field, 5.75)
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
