import XCTest
@testable import GroveCore

final class StatuslineInstallerTests: XCTestCase {
    private let fm = FileManager.default
    private var configDir: URL!     // temp CLAUDE_CONFIG_DIR
    private var supportBin: URL!    // temp app-support bin (NOT ~/Library/.../Grove)
    private var installer: StatuslineInstaller!

    override func setUpWithError() throws {
        configDir = try Fixture.tempDir("statusline-config")
        supportBin = try Fixture.tempDir("statusline-support")
        installer = StatuslineInstaller(scriptDir: supportBin.path)
    }

    private func settingsPath() -> String {
        configDir.appendingPathComponent("settings.json").path
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath()))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - install points settings at the wrapper and saves the original

    func testInstallShipsWrapperAndRepointsSettingsSavingOriginal() throws {
        // Pre-existing settings with a user's own statusLine command.
        let original = "~/.claude/statusline-command.sh"
        try #"{"statusLine":{"type":"command","command":"\#(original)"}}"#
            .write(to: URL(fileURLWithPath: settingsPath()), atomically: true, encoding: .utf8)

        let saved = try installer.install(configDir: configDir.path)

        // The wrapper script exists and is executable under the injected scriptDir.
        let script = installer.scriptPath(forConfigDir: configDir.path)
        XCTAssertTrue(fm.isExecutableFile(atPath: script))
        // settings.json now points at the wrapper, shell-quoted (Claude runs it via sh -c).
        let s = try readSettings()
        let line = try XCTUnwrap(s["statusLine"] as? [String: Any])
        XCTAssertEqual(line["command"] as? String, shellQuote(script))
        // The prior command was returned for AccountConfig.savedStatusline.
        XCTAssertEqual(saved, original)
    }

    func testInstallWithNoPriorStatusLineSavesNil() throws {
        try "{}".write(to: URL(fileURLWithPath: settingsPath()), atomically: true, encoding: .utf8)
        let saved = try installer.install(configDir: configDir.path)
        XCTAssertNil(saved, "no prior statusLine -> nothing to restore")
        let line = try readSettings()["statusLine"] as? [String: Any]
        XCTAssertEqual(line?["command"] as? String,
                       shellQuote(installer.scriptPath(forConfigDir: configDir.path)))
    }

    func testInstallIsIdempotentAndDoesNotOverwriteSavedOriginal() throws {
        let original = "/bin/echo hi"
        try #"{"statusLine":{"type":"command","command":"\#(original)"}}"#
            .write(to: URL(fileURLWithPath: settingsPath()), atomically: true, encoding: .utf8)
        _ = try installer.install(configDir: configDir.path)
        // Second install: settings already points at the wrapper -> savedOriginal must
        // NOT become the wrapper path (that would lose the user's real command).
        let saved = try installer.install(configDir: configDir.path)
        XCTAssertEqual(saved, original, "re-install keeps the user's original, not the wrapper")
    }

    // MARK: - uninstall restores the saved original

    func testUninstallRestoresTheSavedOriginalCommand() throws {
        let original = "/usr/local/bin/my-statusline"
        try #"{"statusLine":{"type":"command","command":"\#(original)"}}"#
            .write(to: URL(fileURLWithPath: settingsPath()), atomically: true, encoding: .utf8)
        _ = try installer.install(configDir: configDir.path)

        try installer.uninstall(configDir: configDir.path, savedStatusline: original)

        let line = try XCTUnwrap(try readSettings()["statusLine"] as? [String: Any])
        XCTAssertEqual(line["command"] as? String, original)
    }

    func testUninstallWithNilSavedRemovesTheStatusLineKey() throws {
        try "{}".write(to: URL(fileURLWithPath: settingsPath()), atomically: true, encoding: .utf8)
        _ = try installer.install(configDir: configDir.path)
        try installer.uninstall(configDir: configDir.path, savedStatusline: nil)
        XCTAssertNil(try readSettings()["statusLine"], "no original -> statusLine removed")
    }

    // MARK: - settings.json goes through HotJSONFile

    /// Claude Code reports a `//` comment as a Settings Error and leaves the file for the
    /// user to fix; an editor can leave it half-written. Install and uninstall used to
    /// read either as `{}` and write back `statusLine` alone (or `{}`), dropping the
    /// account's permissions, env and model. Now both throw and leave every byte, and a
    /// refused install leaves the shipped wrapper and the original baked into it alone.
    func testInstallAndUninstallLeaveSettingsThatDoNotParseByteForByte() throws {
        let original = "/usr/local/bin/my-statusline"
        try #"{"statusLine":{"type":"command","command":"\#(original)"}}"#
            .write(to: URL(fileURLWithPath: settingsPath()), atomically: true, encoding: .utf8)
        _ = try installer.install(configDir: configDir.path)
        let script = installer.scriptPath(forConfigDir: configDir.path)

        let commented = """
            {
              // keep tests fast
              "permissions": { "allow": ["Bash(npm test *)"], "deny": ["Read(./.env)"] },
              "env": { "FOO": "bar" },
              "model": "opus"
            }
            """
        let truncated = #"{"permissions":{"allow":["Bash(npm te"#
        for text in [commented, truncated] {
            let bytes = Data(text.utf8)
            try bytes.write(to: URL(fileURLWithPath: settingsPath()))
            let calls: [() throws -> Void] = [
                { _ = try self.installer.install(configDir: self.configDir.path) },
                { try self.installer.uninstall(configDir: self.configDir.path, savedStatusline: original) },
                { try self.installer.uninstall(configDir: self.configDir.path, savedStatusline: nil) },
            ]
            for call in calls {
                XCTAssertThrowsError(try call()) { error in
                    guard case .unparseable? = error as? HotJSONFile.Failure else {
                        return XCTFail("expected HotJSONFile.Failure.unparseable, got \(error)")
                    }
                }
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: settingsPath())), bytes)
            }
            XCTAssertEqual(StatuslineInstaller.bakedOriginal(inScriptAt: script), original)
        }
    }

    /// A settings.json kept in a dotfiles repo is a symlink. The atomic write used to
    /// replace the link with a regular file and leave the dotfiles copy stale. Now the
    /// change lands in the target, which keeps its mode, and `/` is not written as `\/`.
    func testInstallAndUninstallWriteThroughASymlinkedSettingsFile() throws {
        let dotfiles = try Fixture.tempDir("statusline-dotfiles")
        let target = dotfiles.appendingPathComponent("settings.json")
        try #"{"permissions":{"allow":["Bash(git log *)"]},"apiKeyHelper":"/usr/local/bin/key-helper"}"#
            .write(to: target, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try fm.createSymbolicLink(atPath: settingsPath(), withDestinationPath: target.path)

        _ = try installer.install(configDir: configDir.path)

        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: settingsPath()), target.path)
        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertFalse(text.contains(#"\/"#), text)
        var settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual((settings["statusLine"] as? [String: Any])?["command"] as? String,
                       shellQuote(installer.scriptPath(forConfigDir: configDir.path)))
        XCTAssertEqual(settings["apiKeyHelper"] as? String, "/usr/local/bin/key-helper")
        XCTAssertNotNil(settings["permissions"])
        XCTAssertEqual(try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int, 0o644)

        try installer.uninstall(configDir: configDir.path, savedStatusline: nil)

        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: settingsPath()), target.path)
        settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any])
        XCTAssertNil(settings["statusLine"])
        XCTAssertEqual(settings["apiKeyHelper"] as? String, "/usr/local/bin/key-helper")
        XCTAssertEqual(try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int, 0o644)
    }

    /// A re-install that changes nothing doesn't write settings.json at all.
    func testReinstallLeavesUnchangedSettingsUntouched() throws {
        try #"{"model":"opus"}"#
            .write(to: URL(fileURLWithPath: settingsPath()), atomically: true, encoding: .utf8)
        _ = try installer.install(configDir: configDir.path)
        let before = try fm.attributesOfItem(atPath: settingsPath())

        _ = try installer.install(configDir: configDir.path)

        let after = try fm.attributesOfItem(atPath: settingsPath())
        XCTAssertEqual(before[.systemFileNumber] as? Int, after[.systemFileNumber] as? Int)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }

    /// HotJSONFile creates a missing parent folder; the installer doesn't. An account
    /// folder that isn't there, such as an alias folder the user deleted, makes install
    /// and uninstall throw, as before, and isn't recreated.
    func testInstallAndUninstallDoNotRecreateAMissingConfigDir() throws {
        let gone = configDir.appendingPathComponent("gone").path
        XCTAssertThrowsError(try installer.install(configDir: gone))
        XCTAssertThrowsError(try installer.uninstall(configDir: gone, savedStatusline: "/bin/echo mine"))
        XCTAssertThrowsError(try installer.uninstall(configDir: gone, savedStatusline: nil))
        XCTAssertFalse(fm.fileExists(atPath: gone))
    }

    // MARK: - the wrapper SCRIPT writes a snapshot then calls through (end-to-end)

    func testWrapperScriptTeesStdinToUsageSnapshotThenExecsOriginal() throws {
        // Install with a stub "original" that writes a marker so we prove pass-through.
        let marker = configDir.appendingPathComponent("passthrough.txt").path
        let stubOriginal = "/bin/sh -c 'cat > /dev/null; echo CALLED > \(marker)'"
        try #"{"statusLine":{"type":"command","command":"\#(stubOriginal)"}}"#
            .write(to: URL(fileURLWithPath: settingsPath()), atomically: true, encoding: .utf8)
        _ = try installer.install(configDir: configDir.path)
        let script = installer.scriptPath(forConfigDir: configDir.path)

        // Feed the wrapper a realistic statusline stdin JSON via the injected
        // CLAUDE_CONFIG_DIR + saved-original env the installer bakes in.
        let stdin = #"{"session_id":"sess-xyz","model":{"display_name":"Opus"},"#
            + #""workspace":{"current_dir":"/ws/x"},"cost":{"total_cost_usd":1.5}}"#
        try Fixture.sh("printf %s \(shellQuoteForTest(stdin)) | /bin/sh \(shellQuoteForTest(script))")

        // The wrapper wrote <configDir>/grove/usage/<session_id>.json ...
        let snap = configDir.appendingPathComponent("grove/usage/sess-xyz.json")
        XCTAssertTrue(fm.fileExists(atPath: snap.path), "capture snapshot written")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: snap)) as? [String: Any]
        // The wrapper wraps the raw render under a capturedAt envelope (Task 6's
        // UsageReader reads `raw.session_id`); the raw keys stay readable there.
        let raw = obj?["raw"] as? [String: Any]
        XCTAssertEqual((raw?["session_id"]) as? String, "sess-xyz")
        // ... and called through to the original (marker written).
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: marker), encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines), "CALLED")
    }

    // MARK: - the installed command survives `sh -c` even with spaces in the path

    /// Regression: the production scriptDir is "~/Library/Application Support/Grove/bin"
    /// (a SPACE). Claude Code runs statusLine.command via `sh -c "<command>"`, so an
    /// unquoted path resolved to "…/Library/Application: not found" (exit 127) and the
    /// wrapper never ran — all-zero limits. The command must be shell-quoted.
    func testInstalledCommandRunsThroughShCDespiteSpacesInPath() throws {
        let spacedBin = configDir.appendingPathComponent("Application Support/Grove bin")
        try fm.createDirectory(at: spacedBin, withIntermediateDirectories: true)
        let spacedInstaller = StatuslineInstaller(scriptDir: spacedBin.path)
        try #"{"statusLine":{"type":"command","command":"/bin/cat >/dev/null"}}"#
            .write(to: URL(fileURLWithPath: settingsPath()), atomically: true, encoding: .utf8)
        _ = try spacedInstaller.install(configDir: configDir.path)
        let command = try XCTUnwrap(
            (try readSettings()["statusLine"] as? [String: Any])?["command"] as? String)
        XCTAssertTrue(command.contains(" "), "the spaced wrapper path must appear in the command")

        // Run it EXACTLY as Claude Code does.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        let stdin = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        try proc.run()
        stdin.fileHandleForWriting.write(Data(#"{"session_id":"spaced","cost":{"total_cost_usd":1}}"#.utf8))
        stdin.fileHandleForWriting.closeFile()
        proc.waitUntilExit()

        let snap = configDir.appendingPathComponent("grove/usage/spaced.json")
        XCTAssertTrue(fm.fileExists(atPath: snap.path),
                      "wrapper must run via sh -c despite spaces (exit \(proc.terminationStatus))")
    }

    // MARK: - multi-account: each account gets its own wrapper (no clobber)

    func testTwoAccountsGetIndependentWrappersWithOwnBakedEnv() throws {
        // Account A and B share one installer (one scriptDir) but have distinct
        // CLAUDE_CONFIG_DIRs. Installing B must NOT clobber A's wrapper or baked env
        // (the multi-account regression a single shared script would cause).
        let dirA = try Fixture.tempDir("statusline-A")
        let dirB = try Fixture.tempDir("statusline-B")
        try #"{"statusLine":{"type":"command","command":"A-orig"}}"#
            .write(to: dirA.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try #"{"statusLine":{"type":"command","command":"B-orig"}}"#
            .write(to: dirB.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let savedA = try installer.install(configDir: dirA.path)
        let savedB = try installer.install(configDir: dirB.path)
        XCTAssertEqual(savedA, "A-orig")
        XCTAssertEqual(savedB, "B-orig")

        let scriptA = installer.scriptPath(forConfigDir: dirA.path)
        let scriptB = installer.scriptPath(forConfigDir: dirB.path)
        XCTAssertNotEqual(scriptA, scriptB, "each account gets its own wrapper file")
        XCTAssertTrue(fm.isExecutableFile(atPath: scriptA))
        XCTAssertTrue(fm.isExecutableFile(atPath: scriptB))

        // Each account's settings point at its OWN wrapper.
        func command(in dir: URL) throws -> String? {
            let data = try Data(contentsOf: dir.appendingPathComponent("settings.json"))
            let s = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return (s["statusLine"] as? [String: Any])?["command"] as? String
        }
        XCTAssertEqual(try command(in: dirA), shellQuote(scriptA))
        XCTAssertEqual(try command(in: dirB), shellQuote(scriptB))

        // B's install did NOT clobber A's baked original.
        XCTAssertEqual(StatuslineInstaller.bakedOriginal(inScriptAt: scriptA), "A-orig")
        XCTAssertEqual(StatuslineInstaller.bakedOriginal(inScriptAt: scriptB), "B-orig")
    }

    /// Local POSIX single-quote shell quoting (tests must not depend on GroveCore's).
    private func shellQuoteForTest(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
