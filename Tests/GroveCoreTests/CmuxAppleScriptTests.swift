import XCTest
@testable import GroveCore

/// Pure string-building tests for the AppleScript backend. The AppleScript
/// leg itself (osascript against the real cmux) is integration-verified by
/// `Grove --cmux-probe` (see CmuxProbe).
final class CmuxAppleScriptTests: XCTestCase {

    // MARK: - AppleScript string literals

    func testAppleScriptLiteralEscapesQuotesAndBackslashes() {
        XCTAssertEqual(CmuxAppleScript.appleScriptLiteral(#"He said "hi" \ there"#),
                       #""He said \"hi\" \\ there""#)
    }

    func testAppleScriptLiteralPlainAndEmpty() {
        XCTAssertEqual(CmuxAppleScript.appleScriptLiteral("plain"), "\"plain\"")
        XCTAssertEqual(CmuxAppleScript.appleScriptLiteral(""), "\"\"")
    }

    // MARK: - Ghostty "text:" action payloads

    func testTextActionAppendsCarriageReturnEscape() {
        // The trailing \r must be the two characters backslash + r: the
        // Ghostty action parser is what turns it into the Enter key.
        XCTAssertEqual(CmuxAppleScript.textAction("cd '/tmp/x' && clear"),
                       "text:cd '/tmp/x' && clear" + "\\r")
    }

    func testTextActionDoublesBackslashesForActionParser() {
        XCTAssertEqual(CmuxAppleScript.textAction(#"echo a\b"#),
                       "text:echo a\\\\b\\r")
    }

    func testTextActionReplacesControlCharactersWithSpaces() {
        // Embedded newlines would submit the command early; tabs would
        // trigger shell completion.
        XCTAssertEqual(CmuxAppleScript.textAction("a\nb\tc\rd"),
                       "text:a b c d\\r")
    }

    func testTextActionPreservesUnicodeAndQuotes() {
        XCTAssertEqual(CmuxAppleScript.textAction("cd '/tmp/тест dir' && touch \"f\""),
                       "text:cd '/tmp/тест dir' && touch \"f\"\\r")
    }

    // MARK: - id namespacing ("as:" routes back to the AppleScript backend)

    func testTabIdFromNamespaced() {
        XCTAssertEqual(CmuxAppleScript.tabId(fromNamespaced: "as:ABC-123"), "ABC-123")
        XCTAssertNil(CmuxAppleScript.tabId(fromNamespaced: "ABC-123"))
        XCTAssertNil(CmuxAppleScript.tabId(fromNamespaced: "AS:ABC"))
        XCTAssertEqual(CmuxAppleScript.tabId(fromNamespaced: "as:"), "")
    }
}
