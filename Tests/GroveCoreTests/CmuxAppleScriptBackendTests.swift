import XCTest
@testable import GroveCore

/// Drives the AppleScript cmux backend through a scripted runner (no real
/// osascript): list parsing, select verification + retry, close verification,
/// and the automation-consent error surface.
final class CmuxAppleScriptBackendTests: XCTestCase {
    private let fs = CmuxAppleScript.fieldSeparator
    private let rs = CmuxAppleScript.rowSeparator

    func testListWorkspacesParsesNamespacedRows() async throws {
        let raw = "t1\(fs)Title One\(fs)/a\(rs)t2\(fs)Title Two\(fs)/b\(rs)"
        let backend = CmuxAppleScript(runner: MockRunner(results: [.ok(raw)]))
        let ws = try await backend.listWorkspaces()
        XCTAssertEqual(ws.map(\.id), ["as:t1", "as:t2"])
        XCTAssertEqual(ws.map(\.title), ["Title One", "Title Two"])
        XCTAssertEqual(ws.map(\.currentDirectory), ["/a", "/b"])
    }

    func testListWorkspacesSkipsMalformedRows() async throws {
        let raw = "onlyone\(rs)t2\(fs)Two\(fs)/b\(rs)\(fs)\(fs)\(rs)"   // wrong arity + empty id
        let backend = CmuxAppleScript(runner: MockRunner(results: [.ok(raw)]))
        let ws = try await backend.listWorkspaces()
        XCTAssertEqual(ws.map(\.id), ["as:t2"])
    }

    func testSelectWorkspaceSucceedsWhenSelectedTrue() async throws {
        let runner = MockRunner(results: [.ok("true")])
        try await CmuxAppleScript(runner: runner).selectWorkspace(tabId: "t9")
        XCTAssertEqual(runner.invocations.first?.executable, "/usr/bin/osascript")
        XCTAssertTrue(runner.invocations.first?.args.last?.contains("select tab") ?? false)
    }

    func testSelectWorkspaceThrowsWhenNotFound() async {
        let backend = CmuxAppleScript(runner: MockRunner(results: [.ok("NOTFOUND")]))
        do { try await backend.selectWorkspace(tabId: "gone"); XCTFail("expected throw") }
        catch { XCTAssertTrue("\(error)".localizedCaseInsensitiveContains("not found")) }
    }

    func testSelectWorkspaceExhaustsRetriesWhenNeverSelected() async {
        let backend = CmuxAppleScript(runner: MockRunner(results: [.ok("false"), .ok("false"), .ok("false")]))
        do { try await backend.selectWorkspace(tabId: "t1"); XCTFail("expected throw") }
        catch { XCTAssertTrue("\(error)".localizedCaseInsensitiveContains("did not select")) }
    }

    func testCloseWorkspaceVerifiesTabDisappeared() async throws {
        // fire -> FIRED, then listTabIds -> empty (the tab is gone).
        let backend = CmuxAppleScript(runner: MockRunner(results: [.ok("FIRED"), .ok("")]))
        try await backend.closeWorkspace(tabId: "t1")
    }

    func testCloseWorkspaceThrowsWhenNotFound() async {
        let backend = CmuxAppleScript(runner: MockRunner(results: [.ok("NOTFOUND")]))
        do { try await backend.closeWorkspace(tabId: "x"); XCTFail("expected throw") }
        catch { XCTAssertTrue("\(error)".localizedCaseInsensitiveContains("not found")) }
    }

    func testRunScriptSurfacesAutomationConsentError() async {
        let backend = CmuxAppleScript(runner:
            MockRunner(results: [.fail("execution error: Not authorized to send Apple events -1743")]))
        do { _ = try await backend.listWorkspaces(); XCTFail("expected throw") }
        catch { XCTAssertTrue("\(error)".contains("Automation"), "\(error)") }
    }

    // MARK: - pure helpers

    func testTextActionDoublesBackslashesAndStripsControlChars() {
        let action = CmuxAppleScript.textAction("echo \\ hi\u{7}")
        XCTAssertEqual(action, "text:echo \\\\ hi \\r")   // backslash doubled, BEL -> space, +\r
    }

    func testTabIdNamespaceRoundTrip() {
        XCTAssertEqual(CmuxAppleScript.tabId(fromNamespaced: "as:abc"), "abc")
        XCTAssertNil(CmuxAppleScript.tabId(fromNamespaced: "abc"))
    }
}

private extension ProcessResult {
    static func ok(_ stdout: String = "") -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }
    static func fail(_ stderr: String = "boom", code: Int32 = 1) -> ProcessResult {
        ProcessResult(exitCode: code, stdout: "", stderr: stderr)
    }
}
