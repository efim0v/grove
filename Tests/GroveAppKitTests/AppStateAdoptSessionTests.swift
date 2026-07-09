import XCTest
import GroveCore
@testable import GroveAppKit

/// Tests for AppState.adoptSession + canShareAcrossAccounts (Phase 2 / Task 4).
/// Verifies:
///   1. Non-default account, not live → workspace symlinked into canonical; no actionError.
///   2. Default/canonical account → predicate canShareAcrossAccounts returns false.
///   3. Live session → adoptSession refuses (no symlink created) and sets actionError.
@MainActor
final class AppStateAdoptSessionTests: XCTestCase {

    // MARK: - Setup

    private var root: URL!
    private var configURL: URL!

    override func setUp() async throws {
        root = try FixtureLite.tempDir("appstate-adopt-session")
        configURL = root.appendingPathComponent("config.json")
    }

    /// Builds AppState wired to temp dirs. canonicalDirOverride is always
    /// set so linking never touches the real ~/.claude.
    private func makeState() -> AppState {
        let state = AppState(configStore: ConfigStore(url: configURL))
        state.canonicalDirOverride = root.appendingPathComponent("canonical").path
        state.cmuxHookFile = root.appendingPathComponent("no-hook.json").path
        state.usageLedgerStoreDirOverride = root.appendingPathComponent("ledger").path
        return state
    }

    // MARK: - Helpers

    /// Write a minimal JSONL transcript into `configDir/projects/<mangle(cwd)>/<id>.jsonl`.
    @discardableResult
    private func writeTranscript(
        configDir: URL,
        cwd: String,
        sessionId: String
    ) throws -> URL {
        let mangled = ClaudeService.mangle(cwd)
        let dir = configDir
            .appendingPathComponent("projects")
            .appendingPathComponent(mangled)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","cwd":"\#(cwd)","sessionId":"\#(sessionId)","gitBranch":"main"}"#,
        ]
        let fileURL = dir.appendingPathComponent("\(sessionId).jsonl")
        try lines.joined(separator: "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    // MARK: - Test 1: canShareAcrossAccounts predicate

    func testCanShareAcrossAccountsIsFalseForCanonicalAccount() throws {
        let canonicalDir = root.appendingPathComponent("canonical-predicate").path
        let canonicalAccount = AccountConfig(name: "default", configDir: canonicalDir)

        // The canonical account (expandTilde(configDir) == canonicalDir) must return false.
        XCTAssertFalse(
            AppState.canShareAcrossAccounts(account: canonicalAccount, canonicalDir: canonicalDir),
            "canShareAcrossAccounts must be false for the canonical/default account"
        )
    }

    func testCanShareAcrossAccountsIsTrueForNonDefaultAccount() throws {
        let canonicalDir = root.appendingPathComponent("canonical-predicate").path
        let nonDefaultAccount = AccountConfig(name: "work", configDir: root.appendingPathComponent("work").path)

        XCTAssertTrue(
            AppState.canShareAcrossAccounts(account: nonDefaultAccount, canonicalDir: canonicalDir),
            "canShareAcrossAccounts must be true for a non-canonical account"
        )
    }

    // MARK: - Test 2: adoptSession — non-default, not live → symlinks created

    func testAdoptSessionSymlinksWorkspaceIntoCanonicalForNonDefaultAccount() async throws {
        let canonicalDir = root.appendingPathComponent("canonical")
        let nonDefaultDir = root.appendingPathComponent("work-account")
        let cwd = "/Users/x/Projects/myapp"
        let sessionId = "adopt-session-s1"

        // Create the non-default account's transcript.
        try writeTranscript(configDir: nonDefaultDir, cwd: cwd, sessionId: sessionId)

        let defaultAccount = AccountConfig(name: "default", configDir: canonicalDir.path)
        let workAccount = AccountConfig(name: "work", configDir: nonDefaultDir.path)

        let state = makeState()
        state.canonicalDirOverride = canonicalDir.path
        state.config.accounts = [defaultAccount, workAccount]

        // No live processes — liveProcessValidatorOverride defaults to nil (real check),
        // and there's no real process, so liveness returns false.
        await state.adoptSession(cwd: cwd, account: workAccount)

        // No error.
        XCTAssertNil(state.actionError,
                     "adoptSession for a non-default, non-live session must not set actionError")

        // The work account's projects/<mangled> must now be a SYMLINK into canonical.
        let mangled = ClaudeService.mangle(cwd)
        let accountProjectPath = nonDefaultDir.appendingPathComponent("projects").appendingPathComponent(mangled).path
        let attrs = try FileManager.default.attributesOfItem(atPath: accountProjectPath)
        let fileType = attrs[.type] as? FileAttributeType
        XCTAssertEqual(fileType, FileAttributeType.typeSymbolicLink,
                       "account's projects/<mangled> must be a symlink after adoptSession")

        // The transcript must be reachable under canonical.
        let canonicalTranscript = canonicalDir
            .appendingPathComponent("projects")
            .appendingPathComponent(mangled)
            .appendingPathComponent("\(sessionId).jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalTranscript.path),
                      "transcript must be reachable under canonical after adoption")
    }

    // MARK: - Test 3: adoptSession — canonical account → no-op

    func testAdoptSessionIsNoOpForCanonicalAccount() async throws {
        let canonicalDir = root.appendingPathComponent("canonical-noop")
        let cwd = "/Users/x/Projects/shared"

        let canonicalAccount = AccountConfig(name: "default", configDir: canonicalDir.path)

        let state = makeState()
        state.canonicalDirOverride = canonicalDir.path
        state.config.accounts = [canonicalAccount]

        // adoptSession for the canonical account should do nothing — no symlink, no error.
        await state.adoptSession(cwd: cwd, account: canonicalAccount)

        XCTAssertNil(state.actionError,
                     "adoptSession for the canonical account must set no actionError")

        // Nothing should have been created in canonical (no symlink attempt).
        let mangled = ClaudeService.mangle(cwd)
        let accountProjectPath = canonicalDir
            .appendingPathComponent("projects")
            .appendingPathComponent(mangled).path
        // canonical projects/<mangled> may or may not exist, but crucially no symlink under canonical
        // pointing at itself.
        if FileManager.default.fileExists(atPath: accountProjectPath) {
            // If it exists it must NOT be a symlink (that would be circular).
            let attrs = try FileManager.default.attributesOfItem(atPath: accountProjectPath)
            let fileType = attrs[.type] as? FileAttributeType
            XCTAssertNotEqual(fileType, FileAttributeType.typeSymbolicLink,
                              "canonical account's own projects dir must not become a symlink")
        }
    }

    // MARK: - Test 4: adoptSession — live session → refused, no mutation (SAFETY TEST)

    func testAdoptSessionRefusesWhenSessionIsLive() async throws {
        let canonicalDir = root.appendingPathComponent("canonical-live")
        let nonDefaultDir = root.appendingPathComponent("work-live")
        let cwd = "/Users/x/Projects/live-app"
        let sessionId = "live-session-s1"
        let fakePid: Int32 = 777777

        // Create the non-default account's transcript.
        try writeTranscript(configDir: nonDefaultDir, cwd: cwd, sessionId: sessionId)

        // Write a sessions/<pid>.json to make liveProcesses think it's live.
        let sessionsDir = nonDefaultDir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let pidRecord = """
        {"pid": \(fakePid), "sessionId": "\(sessionId)", "cwd": "\(cwd)", "status": "busy"}
        """
        try pidRecord.write(to: sessionsDir.appendingPathComponent("\(fakePid).json"),
                            atomically: true, encoding: .utf8)

        let defaultAccount = AccountConfig(name: "default", configDir: canonicalDir.path)
        let workAccount = AccountConfig(name: "work", configDir: nonDefaultDir.path)

        let state = makeState()
        state.canonicalDirOverride = canonicalDir.path
        state.config.accounts = [defaultAccount, workAccount]
        // Inject a validator that treats our fake pid as alive.
        state.liveProcessValidatorOverride = { pid in pid == fakePid }

        await state.adoptSession(cwd: cwd, account: workAccount)

        // Must set actionError mentioning the session is running.
        let error = try XCTUnwrap(state.actionError,
                                  "adoptSession for a live session must set actionError")
        XCTAssertTrue(error.lowercased().contains("running") || error.lowercased().contains("live"),
                      "actionError must mention the session is running; got: \(error)")

        // The account's projects dir must NOT be a symlink (adoption was refused).
        let mangled = ClaudeService.mangle(cwd)
        let accountProjectPath = nonDefaultDir
            .appendingPathComponent("projects")
            .appendingPathComponent(mangled).path
        // It should still be a real directory (or absent), NOT a symlink.
        if FileManager.default.fileExists(atPath: accountProjectPath) {
            let attrs = try FileManager.default.attributesOfItem(atPath: accountProjectPath)
            let fileType = attrs[.type] as? FileAttributeType
            XCTAssertNotEqual(fileType, FileAttributeType.typeSymbolicLink,
                              "account's projects/<mangled> must remain a real dir when adoption is refused")
        }
    }
}
