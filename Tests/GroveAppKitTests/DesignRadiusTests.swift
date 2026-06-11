import XCTest
@testable import GroveAppKit

/// Apple 26 corner system (DesignSystem.swift): fixed radii per chrome level
/// plus the concentric helper used when a ConcentricRectangle cannot resolve
/// (mid-card chips far from any container corner).
final class DesignRadiusTests: XCTestCase {
    func testChromeLevelsAreConcentricallyOrdered() {
        XCTAssertEqual(DesignRadius.panel, 18)
        XCTAssertEqual(DesignRadius.card, 16)
        XCTAssertEqual(DesignRadius.field, 10)
        XCTAssertGreaterThan(DesignRadius.panel, DesignRadius.card)
        XCTAssertGreaterThan(DesignRadius.card, DesignRadius.field)
    }

    func testNestedSubtractsTheInset() {
        XCTAssertEqual(DesignRadius.nested(parent: DesignRadius.card, inset: 10), 6)
        XCTAssertEqual(DesignRadius.nested(parent: DesignRadius.panel, inset: 12), 6)
        XCTAssertEqual(DesignRadius.nested(parent: 16, inset: 4), 12)
    }

    func testNestedNeverDropsBelowFourPoints() {
        XCTAssertEqual(DesignRadius.nested(parent: 16, inset: 14), 4)
        XCTAssertEqual(DesignRadius.nested(parent: 10, inset: 24), 4)   // never negative
        XCTAssertEqual(DesignRadius.nested(parent: 4, inset: 0), 4)
    }
}
