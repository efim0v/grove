import XCTest
import GroveCore
@testable import GroveAppKit

/// Tests for AppState.migrateSession (Phase 4A4).
/// Verifies:
///   1. Happy path: source footprint (transcript + tasks + settings) lands in target configDir.
///   2. Source untouched after migration (copy is non-destructive).
///   3. No-op when source account == target account (same name).
@MainActor
final class AppStateMigrateSessionTests: XCTestCase {

    // MARK: - Setup

    private var root: URL!
    private var configURL: URL!

    override func setUp() async throws {
        root = try FixtureLite.tempDir("appstate-migrate-session")
        configURL = root.appendingPathComponent("config.json")
    }

    private func makeState() -> AppState {
        let state = AppState(configStore: ConfigStore(url: configURL))
        // Always override canonicalDir so no real ~/.claude is touched.
        state.canonicalDirOverride = root.appendingPathComponent("canonical").path
        state.cmuxHookFile = root.appendingPathComponent("no-hook.json").path
        state.usageLedgerStoreDirOverride = root.appendingPathComponent("ledger").path
        return state
    }

    // MARK: - Helpers

    /// Write a minimal session footprint into `configDir`:
    ///   projects/<mangle(cwd)>/<id>.jsonl   — transcript
    ///   tasks/<id>/1.json                    — task record
    ///   settings.json                        — with enabledPlugins
    ///   .claude.json                         — projects[cwd] entry (Phase B)
    private func writeSourceFootprint(
        configDir: URL,
        cwd: String,
        sessionId: String
    ) throws {
        let fm = FileManager.default
        let mangled = ClaudeService.mangle(cwd)

        // Transcript
        let projectsDir = configDir
            .appendingPathComponent("projects")
            .appendingPathComponent(mangled)
        try fm.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        let transcript = #"{"type":"user","cwd":"\#(cwd)","sessionId":"\#(sessionId)","gitBranch":"main"}"#
        try transcript.write(to: projectsDir.appendingPathComponent("\(sessionId).jsonl"),
                             atomically: true, encoding: .utf8)

        // Task record
        let tasksDir = configDir
            .appendingPathComponent("tasks")
            .appendingPathComponent(sessionId)
        try fm.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        try #"{"task":"do the thing"}"#.write(to: tasksDir.appendingPathComponent("1.json"),
                                               atomically: true, encoding: .utf8)

        // settings.json with enabledPlugins
        let settings: [String: Any] = ["enabledPlugins": ["sp@m": true]]
        let settingsData = try JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted)
        try settingsData.write(to: configDir.appendingPathComponent("settings.json"), options: .atomic)

        // .claude.json with a projects[cwd] entry so Phase B (migrateProjectConfig) succeeds.
        // The claudeJSONPath helper resolves to <configDir>/.claude.json for non-default accounts.
        let claudeJSON: [String: Any] = ["projects": [cwd: ["allowedTools": ["Bash"]]]]
        let claudeData = try JSONSerialization.data(withJSONObject: claudeJSON, options: .prettyPrinted)
        try claudeData.write(to: configDir.appendingPathComponent(".claude.json"), options: .atomic)
    }

    // MARK: - Test 1: happy path — files land in target

    func testMigrateSessionCopiesFootprintToTarget() async throws {
        let cwd = "/Users/x/Projects/myapp"
        let sessionId = "migrate-s1"
        let sourceDir = root.appendingPathComponent("src-account")
        let targetDir = root.appendingPathComponent("dst-account")

        try writeSourceFootprint(configDir: sourceDir, cwd: cwd, sessionId: sessionId)

        let sourceAccount = AccountConfig(name: "src", configDir: sourceDir.path)
        let targetAccount = AccountConfig(name: "dst", configDir: targetDir.path)

        let state = makeState()
        state.config.accounts = [sourceAccount, targetAccount]

        await state.migrateSession(cwd: cwd, sessionId: sessionId,
                                   from: sourceAccount, to: targetAccount)

        XCTAssertNil(state.actionError, "migrateSession must not set actionError on success; got: \(state.actionError ?? "")")

        let fm = FileManager.default
        let mangled = ClaudeService.mangle(cwd)

        // Transcript must be present in target
        let targetTranscript = targetDir
            .appendingPathComponent("projects")
            .appendingPathComponent(mangled)
            .appendingPathComponent("\(sessionId).jsonl")
        XCTAssertTrue(fm.fileExists(atPath: targetTranscript.path),
                      "transcript must be copied to target: \(targetTranscript.path)")

        // Task record must be present in target
        let targetTask = targetDir
            .appendingPathComponent("tasks")
            .appendingPathComponent(sessionId)
            .appendingPathComponent("1.json")
        XCTAssertTrue(fm.fileExists(atPath: targetTask.path),
                      "task record must be copied to target: \(targetTask.path)")

        // settings.json in target must contain enabledPlugins from source
        let targetSettingsURL = targetDir.appendingPathComponent("settings.json")
        XCTAssertTrue(fm.fileExists(atPath: targetSettingsURL.path),
                      "settings.json must exist in target after migration")
        let data = try Data(contentsOf: targetSettingsURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let plugins = json?["enabledPlugins"] as? [String: Any]
        XCTAssertNotNil(plugins, "enabledPlugins key must be present in migrated settings.json")
    }

    // MARK: - Test 2: source untouched after migration

    func testMigrateSessionDoesNotMutateSource() async throws {
        let cwd = "/Users/x/Projects/untouched"
        let sessionId = "migrate-s2"
        let sourceDir = root.appendingPathComponent("src-noop")
        let targetDir = root.appendingPathComponent("dst-noop")

        try writeSourceFootprint(configDir: sourceDir, cwd: cwd, sessionId: sessionId)

        let sourceAccount = AccountConfig(name: "srcnoop", configDir: sourceDir.path)
        let targetAccount = AccountConfig(name: "dstnoop", configDir: targetDir.path)

        let state = makeState()
        state.config.accounts = [sourceAccount, targetAccount]

        await state.migrateSession(cwd: cwd, sessionId: sessionId,
                                   from: sourceAccount, to: targetAccount)

        let fm = FileManager.default
        let mangled = ClaudeService.mangle(cwd)

        // Source transcript still present
        let srcTranscript = sourceDir
            .appendingPathComponent("projects")
            .appendingPathComponent(mangled)
            .appendingPathComponent("\(sessionId).jsonl")
        XCTAssertTrue(fm.fileExists(atPath: srcTranscript.path),
                      "source transcript must remain untouched after migration")

        // Source settings.json still present
        XCTAssertTrue(fm.fileExists(atPath: sourceDir.appendingPathComponent("settings.json").path),
                      "source settings.json must remain after migration")
    }

    // MARK: - Test 3: no-op when source == target (same name)

    func testMigrateSessionIsNoOpWhenSameAccount() async throws {
        let cwd = "/Users/x/Projects/same"
        let sessionId = "migrate-s3"
        let sourceDir = root.appendingPathComponent("same-account")

        try writeSourceFootprint(configDir: sourceDir, cwd: cwd, sessionId: sessionId)

        let account = AccountConfig(name: "same", configDir: sourceDir.path)

        let state = makeState()
        state.config.accounts = [account]

        // Record what exists in sourceDir before
        let settingsURL = sourceDir.appendingPathComponent("settings.json")
        let beforeData = try Data(contentsOf: settingsURL)

        await state.migrateSession(cwd: cwd, sessionId: sessionId,
                                   from: account, to: account)

        XCTAssertNil(state.actionError,
                     "migrateSession same→same must not set actionError")

        // Source settings unchanged (no mutation = same bytes)
        let afterData = try Data(contentsOf: settingsURL)
        XCTAssertEqual(beforeData, afterData,
                       "source settings must be byte-identical when source==target (no-op)")
    }
}
