import XCTest
@testable import GroveCore

/// Tests for ClaudeService.isSessionLive(among:cwd:sessionId:) — the pure
/// predicate that guards adoptSession against moving an open transcript.
///
/// RED cases prove the BUG before the fix:
///   - A table-only live process (cwd == "", sessionId == "S1") is NOT matched
///     by the old cwd-only logic → data-loss guard passes when it should refuse.
///
/// GREEN cases prove the FIX:
///   - Same table-only process IS matched when sessionId is also checked.
final class SessionLivePredicateTests: XCTestCase {

    // MARK: - Table-only (--resume / --session-id) session — THE BUG CASE

    /// A live process with cwd=="" and sessionId=="S1" (the common --resume path)
    /// must block adoption of the session with id "S1", regardless of cwd.
    func testTableOnlyLiveSessionIsDetectedBySessionId() {
        let tableProcess = LiveProcess(pid: 1001, sessionId: "S1", cwd: "",
                                      status: "idle", accountName: "")
        let result = ClaudeService.isSessionLive(
            among: [tableProcess],
            cwd: "/Users/x/Projects/myapp",
            sessionId: "S1"
        )
        XCTAssertTrue(result,
            "A table-only live process (cwd==\"\") must be detected via sessionId match")
    }

    // MARK: - Cwd-match still works (regression guard)

    /// A live process carrying cwd (fresh session, no --resume) must still match
    /// by cwd even when the session ids differ.
    func testCwdMatchStillWorks() {
        let freshProcess = LiveProcess(pid: 1002, sessionId: "", cwd: "/Users/x/Projects/myapp",
                                      status: "idle", accountName: "")
        let result = ClaudeService.isSessionLive(
            among: [freshProcess],
            cwd: "/Users/x/Projects/myapp",
            sessionId: "S2"
        )
        XCTAssertTrue(result,
            "A fresh (cwd-carried) live process must still match via cwd")
    }

    // MARK: - Empty sessionId must not match empty-id table process (false-match guard)

    /// When the adoption request has an empty sessionId (should not happen in
    /// practice, but must not match a table-only process that also has empty cwd).
    func testEmptySessionIdDoesNotMatchEmptyCwdTableProcess() {
        let tableProcess = LiveProcess(pid: 1003, sessionId: "", cwd: "",
                                      status: "idle", accountName: "")
        let result = ClaudeService.isSessionLive(
            among: [tableProcess],
            cwd: "/Users/x/Projects/oops",
            sessionId: ""
        )
        XCTAssertFalse(result,
            "An empty sessionId must not match a table-only process (prevents false positive)")
    }

    // MARK: - Non-matching session → false

    func testNonMatchingSessionReturnsFalse() {
        let tableProcess = LiveProcess(pid: 1004, sessionId: "S1", cwd: "/other/path",
                                      status: "idle", accountName: "")
        let result = ClaudeService.isSessionLive(
            among: [tableProcess],
            cwd: "/Users/x/Projects/myapp",
            sessionId: "S99"
        )
        XCTAssertFalse(result,
            "No matching process → isSessionLive must return false")
    }

    // MARK: - Empty live array → false

    func testEmptyLiveArrayReturnsFalse() {
        let result = ClaudeService.isSessionLive(
            among: [],
            cwd: "/Users/x/Projects/myapp",
            sessionId: "S1"
        )
        XCTAssertFalse(result, "Empty live array must return false")
    }
}
