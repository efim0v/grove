import XCTest
@testable import GroveAppKit

/// Apple 26 corner system (DesignSystem.swift): fixed radii per chrome level
/// plus the concentric helper used when a ConcentricRectangle cannot resolve
/// (mid-card chips far from any container corner). v1.2.1 fix 3 bumped the
/// whole scale to match macOS/iOS 26 (cards 16 -> 22, fields 10 -> 14, floor
/// 4 -> 8; panel follows to 26 so the concentric ordering holds).
final class DesignRadiusTests: XCTestCase {
    func testChromeLevelsAreConcentricallyOrdered() {
        XCTAssertEqual(DesignRadius.panel, 26)
        XCTAssertEqual(DesignRadius.card, 22)
        XCTAssertEqual(DesignRadius.field, 14)
        XCTAssertGreaterThan(DesignRadius.panel, DesignRadius.card)
        XCTAssertGreaterThan(DesignRadius.card, DesignRadius.field)
    }

    func testNestedSubtractsTheInset() {
        XCTAssertEqual(DesignRadius.nested(parent: DesignRadius.card, inset: 10), 12)
        XCTAssertEqual(DesignRadius.nested(parent: DesignRadius.panel, inset: 12), 14)
        XCTAssertEqual(DesignRadius.nested(parent: 22, inset: 4), 18)
    }

    func testNestedNeverDropsBelowEightPoints() {
        XCTAssertEqual(DesignRadius.nested(parent: 22, inset: 16), 8)
        XCTAssertEqual(DesignRadius.nested(parent: 14, inset: 24), 8)   // never negative
        XCTAssertEqual(DesignRadius.nested(parent: 8, inset: 0), 8)
    }
}
