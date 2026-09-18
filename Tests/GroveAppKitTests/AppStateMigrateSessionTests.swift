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
        // migrateSession now auto-installs the statusline wrapper (Phase 5A); keep that
        // script write inside a temp dir, never the real ~/Library/Application Support.
        state.statuslineScriptDirOverride = root.appendingPathComponent("statusline-bin").path
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

    // MARK: - Test 4: live-target guard — refused when TARGET account has a running process

    /// Injects a live process attributed to the TARGET account via allLiveProcessesOverride.
    /// migrateSession must refuse (set actionError mentioning "running") and must NOT
    /// copy any files to the target configDir.
    func testMigrateSessionRefusesWhenTargetAccountHasLiveProcess() async throws {
        let cwd = "/Users/x/Projects/live-target"
        let sessionId = "migrate-live-target-s1"
        let sourceDir = root.appendingPathComponent("src-live-guard")
        let targetDir = root.appendingPathComponent("dst-live-guard")

        try writeSourceFootprint(configDir: sourceDir, cwd: cwd, sessionId: sessionId)

        let sourceAccount = AccountConfig(name: "src-lg", configDir: sourceDir.path)
        let targetAccount = AccountConfig(name: "dst-lg", configDir: targetDir.path)

        let state = makeState()
        state.config.accounts = [sourceAccount, targetAccount]

        // Inject a live process attributed to the TARGET account — any live session is enough
        let liveProcess = LiveProcess(pid: 12345, sessionId: "some-other-session",
                                     cwd: "/some/other/cwd", status: "busy",
                                     accountName: targetAccount.name)
        state.allLiveProcessesOverride = [liveProcess]

        await state.migrateSession(cwd: cwd, sessionId: sessionId,
                                   from: sourceAccount, to: targetAccount)

        // Must have set actionError mentioning the session is running
        let error = try XCTUnwrap(state.actionError,
                                   "migrateSession must set actionError when target account has a live process")
        XCTAssertTrue(error.lowercased().contains("running"),
                      "actionError must mention 'running'; got: \(error)")
        XCTAssertTrue(error.contains(targetAccount.name),
                      "actionError must mention the target account name '\(targetAccount.name)'; got: \(error)")

        // Target configDir must remain empty — no transcript, no settings.json, nothing
        let fm = FileManager.default
        let mangled = ClaudeService.mangle(cwd)
        let targetTranscript = targetDir
            .appendingPathComponent("projects")
            .appendingPathComponent(mangled)
            .appendingPathComponent("\(sessionId).jsonl")
        XCTAssertFalse(fm.fileExists(atPath: targetTranscript.path),
                       "target transcript must NOT exist when migration was refused")
        let targetSettings = targetDir.appendingPathComponent("settings.json")
        XCTAssertFalse(fm.fileExists(atPath: targetSettings.path),
                       "target settings.json must NOT exist when migration was refused")
    }

    /// Happy-path complement: with NO live processes, migrateSession proceeds normally.
    func testMigrateSessionProceedsWhenTargetAccountHasNoLiveProcess() async throws {
        let cwd = "/Users/x/Projects/not-live-target"
        let sessionId = "migrate-not-live-s1"
        let sourceDir = root.appendingPathComponent("src-no-live")
        let targetDir = root.appendingPathComponent("dst-no-live")

        try writeSourceFootprint(configDir: sourceDir, cwd: cwd, sessionId: sessionId)

        let sourceAccount = AccountConfig(name: "src-nl", configDir: sourceDir.path)
        let targetAccount = AccountConfig(name: "dst-nl", configDir: targetDir.path)

        let state = makeState()
        state.config.accounts = [sourceAccount, targetAccount]
        // No live processes at all
        state.allLiveProcessesOverride = []

        await state.migrateSession(cwd: cwd, sessionId: sessionId,
                                   from: sourceAccount, to: targetAccount)

        XCTAssertNil(state.actionError,
                     "migrateSession with no live target processes must not set actionError; got: \(state.actionError ?? "")")

        // Transcript must land in target
        let mangled = ClaudeService.mangle(cwd)
        let targetTranscript = targetDir
            .appendingPathComponent("projects")
            .appendingPathComponent(mangled)
            .appendingPathComponent("\(sessionId).jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetTranscript.path),
                      "transcript must land in target when no live processes block migration")
    }

    /// Phase 5A: migrating a session into a target account also auto-installs the
    /// grove statusline wrapper on the TARGET, so the newly-populated account starts
    /// capturing usage. Best-effort; runs only when migration proceeds (no live target).
    func testMigrateSessionAutoInstallsStatuslineOnTarget() async throws {
        let cwd = "/Users/x/Projects/migrate-monitor"
        let sessionId = "migrate-mon-s1"
        let sourceDir = root.appendingPathComponent("src-mon")
        let targetDir = root.appendingPathComponent("dst-mon")

        try writeSourceFootprint(configDir: sourceDir, cwd: cwd, sessionId: sessionId)

        let sourceAccount = AccountConfig(name: "src-mon", configDir: sourceDir.path)
        let targetAccount = AccountConfig(name: "dst-mon", configDir: targetDir.path)

        let state = makeState()
        state.config.accounts = [sourceAccount, targetAccount]
        state.allLiveProcessesOverride = []

        await state.migrateSession(cwd: cwd, sessionId: sessionId,
                                   from: sourceAccount, to: targetAccount)

        XCTAssertNil(state.actionError,
                     "migrateSession must not set actionError on success; got: \(state.actionError ?? "")")

        // The TARGET's settings.json now points at the grove wrapper.
        let data = try Data(contentsOf: targetDir.appendingPathComponent("settings.json"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let command = (obj?["statusLine"] as? [String: Any])?["command"] as? String
        XCTAssertNotNil(command)
        XCTAssertTrue(command?.contains("grove-statusline-") == true,
                      "migrateSession must repoint the target's statusLine at the grove wrapper; got \(command ?? "nil")")
        // Target account marked monitored; source had no statusLine so nothing to preserve.
        let target = state.config.accounts.first { $0.name == "dst-mon" }
        XCTAssertEqual(target?.monitoring, true)
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
