import XCTest
import SwiftUI
@testable import GroveAppKit
import GroveCore

final class ProjectAccentTests: XCTestCase {
    func testDefaultIndexIsDeterministicAndInRange() {
        let id = UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!
        let i = ProjectAccent.defaultIndex(id)
        XCTAssertEqual(i, ProjectAccent.defaultIndex(id))           // stable across calls
        XCTAssertTrue(i >= 0 && i < ProjectAccent.palette.count)
        XCTAssertEqual(ProjectAccent.paletteHex.count, ProjectAccent.palette.count)
    }

    func testExplicitAccentOverridesDefault() {
        var p = ProjectConfig(name: "x", path: "/x")
        let auto = ProjectAccent.color(for: p)
        p.accentColor = "#FF0000"
        XCTAssertEqual(ProjectAccent.color(for: p), Color(.sRGB, red: 1, green: 0, blue: 0))
        XCTAssertNotEqual(ProjectAccent.color(for: p), auto)
    }

    func testColorHexParsing() {
        XCTAssertNotNil(Color(hex: "#0A84FF"))
        XCTAssertNotNil(Color(hex: "0A84FF"))
        XCTAssertEqual(Color(hex: "#F00"), Color(.sRGB, red: 1, green: 0, blue: 0))   // shorthand
        XCTAssertNil(Color(hex: "nothex"))
        XCTAssertNil(Color(hex: "#12"))
    }
}
