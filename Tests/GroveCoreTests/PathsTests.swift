import XCTest
import GroveCore

final class PathsTests: XCTestCase {
    func testExpandTildeAlone() {
        XCTAssertEqual(expandTilde("~"), NSHomeDirectory())
    }

    func testExpandTildePrefix() {
        XCTAssertEqual(expandTilde("~/Projects/grove"), NSHomeDirectory() + "/Projects/grove")
    }

    func testExpandTildeAbsolutePathUnchanged() {
        XCTAssertEqual(expandTilde("/usr/local/bin"), "/usr/local/bin")
    }

    func testExpandTildeRelativePathUnchanged() {
        XCTAssertEqual(expandTilde("relative/path"), "relative/path")
    }

    func testShellQuotePlain() {
        XCTAssertEqual(shellQuote("plain"), "'plain'")
    }

    func testShellQuoteSpacesAndDollarStayLiteral() {
        XCTAssertEqual(shellQuote("a b $HOME"), "'a b $HOME'")
    }

    func testShellQuoteEmbeddedSingleQuote() {
        XCTAssertEqual(shellQuote("it's"), "'it'\\''s'")
    }

    func testShellQuoteRoundTripThroughShell() throws {
        let tricky = "it's a \"test\" with $HOME, spaces & 'quotes'"
        let out = try Fixture.sh("printf '%s' \(shellQuote(tricky))")
        XCTAssertEqual(out, tricky)
    }
}
