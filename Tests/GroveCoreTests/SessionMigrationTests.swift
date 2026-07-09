import XCTest
@testable import GroveCore

final class SessionMigrationTests: XCTestCase {

    // MARK: - deepMergeJSON

    func testDeepMergeNestedDictsMergeRecursively() {
        let target: [String: Any] = ["a": ["x": 1, "y": 2]]
        let source: [String: Any] = ["a": ["y": 99, "z": 3]]
        let result = SessionMigration.deepMergeJSON(target: target, source: source)
        let inner = result["a"] as? [String: Any]
        XCTAssertEqual(inner?["x"] as? Int, 1, "target-only key preserved in nested dict")
        XCTAssertEqual(inner?["y"] as? Int, 2, "target wins on conflict in nested dict")
        XCTAssertEqual(inner?["z"] as? Int, 3, "source-only key added in nested dict")
    }

    func testDeepMergeArrayUnionDeduplicates() {
        let target: [String: Any] = ["arr": [1, 2, 3]]
        let source: [String: Any] = ["arr": [2, 3, 4]]
        let result = SessionMigration.deepMergeJSON(target: target, source: source)
        let arr = result["arr"] as? [Int]
        XCTAssertEqual(arr, [1, 2, 3, 4], "array union appends source elements not in target")
    }

    func testDeepMergeScalarTargetWins() {
        let target: [String: Any] = ["key": "target-value"]
        let source: [String: Any] = ["key": "source-value"]
        let result = SessionMigration.deepMergeJSON(target: target, source: source)
        XCTAssertEqual(result["key"] as? String, "target-value", "target scalar wins")
    }

    func testDeepMergeSourceOnlyKeyAdded() {
        let target: [String: Any] = ["existing": 1]
        let source: [String: Any] = ["new-key": "hello"]
        let result = SessionMigration.deepMergeJSON(target: target, source: source)
        XCTAssertEqual(result["existing"] as? Int, 1)
        XCTAssertEqual(result["new-key"] as? String, "hello", "source-only key is added")
    }

    func testDeepMergeTargetOnlyKeyPreserved() {
        let target: [String: Any] = ["only-in-target": 42]
        let source: [String: Any] = ["other": "val"]
        let result = SessionMigration.deepMergeJSON(target: target, source: source)
        XCTAssertEqual(result["only-in-target"] as? Int, 42, "target-only key never removed")
    }

    func testDeepMergeBoolPreserved() {
        // NSNumber wraps both Bool and Int; must not conflate them
        let target: [String: Any] = ["flag": true, "count": 5]
        let source: [String: Any] = ["other": false]
        let result = SessionMigration.deepMergeJSON(target: target, source: source)
        let flag = result["flag"]
        let other = result["other"]
        // Verify types round-trip correctly
        XCTAssertTrue(flag is Bool || (flag as? NSNumber)?.boolValue == true, "bool preserved as bool")
        XCTAssertTrue(other is Bool || (other as? NSNumber)?.boolValue == false, "source bool added")
        XCTAssertEqual(result["count"] as? Int, 5, "number preserved")
    }

    func testDeepMergeArrayOfDictsDeduplicatedByJSONEncoding() {
        let entry1: [String: Any] = ["id": "a"]
        let entry2: [String: Any] = ["id": "b"]
        let target: [String: Any] = ["items": [entry1]]
        let source: [String: Any] = ["items": [entry1, entry2]]  // entry1 is duplicate
        let result = SessionMigration.deepMergeJSON(target: target, source: source)
        let items = result["items"] as? [[String: Any]]
        XCTAssertEqual(items?.count, 2, "duplicate dict entry removed; unique one appended")
        XCTAssertEqual(items?.last?["id"] as? String, "b")
    }

    // MARK: - mergeSettingsKeys

    func testMergeSettingsKeysEnabledPluginsUnion() {
        let target: [String: Any] = ["enabledPlugins": ["A": true]]
        let source: [String: Any] = ["enabledPlugins": ["B": true]]
        let result = SessionMigration.mergeSettingsKeys(target: target, source: source, keys: ["enabledPlugins"])
        let plugins = result["enabledPlugins"] as? [String: Bool]
        XCTAssertEqual(plugins?["A"], true, "target plugin preserved")
        XCTAssertEqual(plugins?["B"], true, "source plugin added")
    }

    func testMergeSettingsKeysModelScalarTargetWins() {
        let target: [String: Any] = ["model": "claude-3-5"]
        let source: [String: Any] = ["model": "claude-opus-4"]
        let result = SessionMigration.mergeSettingsKeys(target: target, source: source, keys: ["model"])
        XCTAssertEqual(result["model"] as? String, "claude-3-5", "target model wins")
    }

    func testMergeSettingsKeysCopiesWhenTargetLacksKey() {
        let target: [String: Any] = ["model": "claude-3"]
        let source: [String: Any] = ["statusLine": "some-format"]
        let result = SessionMigration.mergeSettingsKeys(target: target, source: source, keys: ["statusLine"])
        XCTAssertEqual(result["statusLine"] as? String, "some-format", "missing key copied from source")
    }

    func testMergeSettingsKeysUnlistedSourceKeyIgnored() {
        let target: [String: Any] = ["model": "claude-3"]
        let source: [String: Any] = ["secretField": "should-not-appear", "model": "override"]
        let result = SessionMigration.mergeSettingsKeys(target: target, source: source, keys: ["model"])
        XCTAssertNil(result["secretField"], "unlisted key from source must not appear in result")
    }

    func testMergeSettingsKeysUnrelatedTargetKeysUntouched() {
        let target: [String: Any] = ["model": "claude-3", "unrelated": "keep-me"]
        let source: [String: Any] = ["model": "override"]
        let result = SessionMigration.mergeSettingsKeys(target: target, source: source, keys: ["model"])
        XCTAssertEqual(result["unrelated"] as? String, "keep-me", "unrelated target key untouched")
    }

    // MARK: - mergeClaudeProjectEntry

    func testMergeClaudeProjectEntryAddsNewCwd() {
        let targetHome: [String: Any] = ["version": 1, "projects": [String: Any]()]
        let sourceEntry: [String: Any] = ["allowedTools": ["Bash"]]
        let result = SessionMigration.mergeClaudeProjectEntry(
            targetHomeJSON: targetHome,
            sourceEntry: sourceEntry,
            cwd: "/work/myproject"
        )
        let projects = result["projects"] as? [String: Any]
        let entry = projects?["/work/myproject"] as? [String: Any]
        XCTAssertEqual(entry?["allowedTools"] as? [String], ["Bash"], "new cwd entry created")
    }

    func testMergeClaudeProjectEntryDeepMergesExistingCwd() {
        let existingEntry: [String: Any] = ["allowedTools": ["Bash"], "theme": "dark"]
        let targetHome: [String: Any] = ["projects": ["/work/proj": existingEntry]]
        let sourceEntry: [String: Any] = ["allowedTools": ["Read"], "model": "opus"]
        let result = SessionMigration.mergeClaudeProjectEntry(
            targetHomeJSON: targetHome,
            sourceEntry: sourceEntry,
            cwd: "/work/proj"
        )
        let projects = result["projects"] as? [String: Any]
        let entry = projects?["/work/proj"] as? [String: Any]
        let tools = entry?["allowedTools"] as? [String]
        XCTAssertTrue(tools?.contains("Bash") == true, "target tools preserved")
        XCTAssertTrue(tools?.contains("Read") == true, "source tool added")
        XCTAssertEqual(entry?["theme"] as? String, "dark", "target-only key preserved in merge")
        XCTAssertEqual(entry?["model"] as? String, "opus", "source-only key added")
    }

    func testMergeClaudeProjectEntryOtherProjectsUntouched() {
        let targetHome: [String: Any] = [
            "projects": [
                "/other/project": ["model": "haiku"]
            ]
        ]
        let result = SessionMigration.mergeClaudeProjectEntry(
            targetHomeJSON: targetHome,
            sourceEntry: ["theme": "dark"],
            cwd: "/new/project"
        )
        let projects = result["projects"] as? [String: Any]
        let other = projects?["/other/project"] as? [String: Any]
        XCTAssertEqual(other?["model"] as? String, "haiku", "other project entries untouched")
    }

    func testMergeClaudeProjectEntryTopLevelKeysUntouched() {
        let targetHome: [String: Any] = ["version": 3, "projects": [String: Any]()]
        let result = SessionMigration.mergeClaudeProjectEntry(
            targetHomeJSON: targetHome,
            sourceEntry: [:],
            cwd: "/p"
        )
        XCTAssertEqual(result["version"] as? Int, 3, "top-level version key untouched")
    }

    func testMergeClaudeProjectEntryCreatesProjectsDictIfAbsent() {
        let targetHome: [String: Any] = ["version": 1]  // no "projects" key
        let result = SessionMigration.mergeClaudeProjectEntry(
            targetHomeJSON: targetHome,
            sourceEntry: ["model": "sonnet"],
            cwd: "/my/proj"
        )
        let projects = result["projects"] as? [String: Any]
        XCTAssertNotNil(projects, "projects dict created when absent")
        let entry = projects?["/my/proj"] as? [String: Any]
        XCTAssertEqual(entry?["model"] as? String, "sonnet")
    }

    // MARK: - repointPluginInstallPaths

    func testRepointPluginInstallPathsRewritesMatchingPrefix() {
        let installedPlugins: [String: Any] = [
            "version": 2,
            "plugins": [
                "myplugin@market": [
                    ["installPath": "/Users/alice/.config/claude/plugins/cache/foo", "name": "foo"]
                ]
            ]
        ]
        let result = SessionMigration.repointPluginInstallPaths(
            installedPlugins: installedPlugins,
            fromConfigDir: "/Users/alice/.config/claude",
            toConfigDir: "/Users/bob/.config/claude"
        )
        let plugins = result["plugins"] as? [String: Any]
        let entries = plugins?["myplugin@market"] as? [[String: Any]]
        XCTAssertEqual(
            entries?.first?["installPath"] as? String,
            "/Users/bob/.config/claude/plugins/cache/foo",
            "prefix rewritten from→to"
        )
    }

    func testRepointPluginInstallPathsLeavesNonMatchingPathAlone() {
        let installedPlugins: [String: Any] = [
            "version": 2,
            "plugins": [
                "otherplugin@mkt": [
                    ["installPath": "/totally/different/path/plugin", "name": "p"]
                ]
            ]
        ]
        let result = SessionMigration.repointPluginInstallPaths(
            installedPlugins: installedPlugins,
            fromConfigDir: "/Users/alice/.config/claude",
            toConfigDir: "/Users/bob/.config/claude"
        )
        let plugins = result["plugins"] as? [String: Any]
        let entries = plugins?["otherplugin@mkt"] as? [[String: Any]]
        XCTAssertEqual(
            entries?.first?["installPath"] as? String,
            "/totally/different/path/plugin",
            "non-matching path unchanged"
        )
    }

    func testRepointPluginInstallPathsVersionAndOtherFieldsPreserved() {
        let installedPlugins: [String: Any] = ["version": 2, "plugins": [String: Any]()]
        let result = SessionMigration.repointPluginInstallPaths(
            installedPlugins: installedPlugins,
            fromConfigDir: "/a",
            toConfigDir: "/b"
        )
        XCTAssertEqual(result["version"] as? Int, 2, "version field preserved")
    }

    func testRepointPluginInstallPathsHandlesMissingPluginsKey() {
        let installedPlugins: [String: Any] = ["version": 2]  // no "plugins" key
        let result = SessionMigration.repointPluginInstallPaths(
            installedPlugins: installedPlugins,
            fromConfigDir: "/a",
            toConfigDir: "/b"
        )
        XCTAssertEqual(result["version"] as? Int, 2, "does not crash on missing plugins key")
    }

    func testRepointPluginInstallPathsRewritesOnlyPrefixOnce() {
        // Ensure only the leading prefix is replaced, not all occurrences.
        // The path embeds fromConfigDir a second time after a double-slash.
        let from = "/Users/alice/.config/claude"
        let path = "\(from)/plugins/cache/\(from)/weird"
        let installedPlugins: [String: Any] = [
            "version": 2,
            "plugins": [
                "p@m": [["installPath": path]]
            ]
        ]
        let result = SessionMigration.repointPluginInstallPaths(
            installedPlugins: installedPlugins,
            fromConfigDir: from,
            toConfigDir: "/Users/bob/.config/claude"
        )
        let plugins = result["plugins"] as? [String: Any]
        let entries = plugins?["p@m"] as? [[String: Any]]
        let rewritten = entries?.first?["installPath"] as? String
        // The leading prefix must be bob's path
        XCTAssertTrue(
            rewritten?.hasPrefix("/Users/bob/.config/claude") == true,
            "prefix rewritten to toConfigDir"
        )
        // The embedded second occurrence of alice's dir must survive intact
        XCTAssertTrue(
            rewritten?.contains("/Users/alice/.config/claude/weird") == true,
            "only the leading prefix replaced; embedded occurrence of fromConfigDir left alone"
        )
    }

    // MARK: - copySessionData

    private let fm = FileManager.default

    /// Writes `content` to `dir/rel`, creating intermediate dirs.
    private func write(_ content: String, at dir: URL, _ rel: String) throws {
        let url = dir.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ dir: URL, _ rel: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8)
    }

    private func exists(_ dir: URL, _ rel: String) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent(rel).path)
    }

    /// Returns a snapshot of every file path under `dir` → content.
    private func snapshot(_ dir: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        guard let enumerator = fm.enumerator(atPath: dir.path) else { return result }
        for case let rel as String in enumerator {
            let full = dir.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            result[rel] = (try? String(contentsOf: full, encoding: .utf8)) ?? ""
        }
        return result
    }

    /// 1. Happy path — full source footprint copies to target; source is unchanged.
    func testCopySessionDataHappyPath() throws {
        let root = try Fixture.tempDir("migrate-happy")
        let from = root.appendingPathComponent("from")
        let to = root.appendingPathComponent("to")
        let cwd = "/Users/alice/myproject"
        let id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let mangled = ClaudeService.mangle(cwd)
        let accountKey = "testkey1"

        // Build source footprint
        try write("transcript line\n", at: from, "projects/\(mangled)/\(id).jsonl")
        try write("subagent data\n",   at: from, "projects/\(mangled)/\(id)/subagents/x.jsonl")
        try write("memory content\n",  at: from, "projects/\(mangled)/memory/MEMORY.md")
        try write("file-history\n",    at: from, "file-history/\(id)/f.txt")
        try write("task data\n",       at: from, "tasks/\(id)/1.json")
        try fm.createDirectory(at: from.appendingPathComponent("session-env/\(id)"),
                               withIntermediateDirectories: true)
        try write("usage json\n",      at: from, "grove/usage/\(id).json")

        let sourceBefore = try snapshot(from)

        let report = SessionMigration.copySessionData(
            sessionId: id, cwd: cwd,
            fromConfigDir: from.path, toConfigDir: to.path,
            mirrorRoot: nil, fromAccountKey: accountKey
        )

        XCTAssertTrue(report.issues.isEmpty, "no issues expected; got: \(report.issues)")
        XCTAssertFalse(report.copied.isEmpty, "should have copied items")

        XCTAssertEqual(try read(to, "projects/\(mangled)/\(id).jsonl"), "transcript line\n")
        XCTAssertEqual(try read(to, "projects/\(mangled)/\(id)/subagents/x.jsonl"), "subagent data\n")
        XCTAssertEqual(try read(to, "projects/\(mangled)/memory/MEMORY.md"), "memory content\n")
        XCTAssertEqual(try read(to, "file-history/\(id)/f.txt"), "file-history\n")
        XCTAssertEqual(try read(to, "tasks/\(id)/1.json"), "task data\n")
        XCTAssertTrue(fm.fileExists(atPath: to.appendingPathComponent("session-env/\(id)").path),
                      "session-env dir must exist at target")
        XCTAssertEqual(try read(to, "grove/usage/\(id).json"), "usage json\n")

        // Source must be byte-identical after copy
        XCTAssertEqual(try snapshot(from), sourceBefore, "source changed — violation of non-destructive contract")
    }

    /// 2. Mirror fallback — transcript absent under projects/ but present in the mirror.
    func testCopySessionDataMirrorFallback() throws {
        let root = try Fixture.tempDir("migrate-mirror")
        let from = root.appendingPathComponent("from")
        let to = root.appendingPathComponent("to")
        let cwd = "/Users/alice/myproject"
        let id = "aaaaaaaa-bbbb-cccc-dddd-ffffffffffff"
        let mangled = ClaudeService.mangle(cwd)
        let accountKey = "myacckey"
        let canonicalDir = root.appendingPathComponent("canonical")
        let mirrorRoot = TranscriptMirror.mirrorRoot(canonicalDir: canonicalDir.path)

        // No transcript under projects/; place it in the mirror
        let mirrorPath = "\(mirrorRoot)/\(accountKey)/\(mangled)/\(id).jsonl"
        try fm.createDirectory(at: URL(fileURLWithPath: mirrorPath).deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try "mirror transcript\n".write(toFile: mirrorPath, atomically: true, encoding: .utf8)

        let report = SessionMigration.copySessionData(
            sessionId: id, cwd: cwd,
            fromConfigDir: from.path, toConfigDir: to.path,
            mirrorRoot: mirrorRoot, fromAccountKey: accountKey
        )

        XCTAssertTrue(report.issues.isEmpty, "no issues: \(report.issues)")
        XCTAssertEqual(try read(to, "projects/\(mangled)/\(id).jsonl"), "mirror transcript\n",
                       "transcript should be copied from mirror")
    }

    /// 3. Neither transcript source → issue recorded, other items still copy.
    func testCopySessionDataNeitherTranscriptSource() throws {
        let root = try Fixture.tempDir("migrate-no-transcript")
        let from = root.appendingPathComponent("from")
        let to = root.appendingPathComponent("to")
        let cwd = "/Users/alice/myproject"
        let id = "aaaaaaaa-bbbb-cccc-dddd-000000000000"
        let mangled = ClaudeService.mangle(cwd)

        // Only the usage file, no transcript anywhere
        try write("usage\n", at: from, "grove/usage/\(id).json")

        let report = SessionMigration.copySessionData(
            sessionId: id, cwd: cwd,
            fromConfigDir: from.path, toConfigDir: to.path,
            mirrorRoot: nil, fromAccountKey: "key"
        )

        XCTAssertFalse(report.issues.isEmpty, "should record issue for missing transcript")
        XCTAssertTrue(report.issues.contains { $0.lowercased().contains("transcript") },
                      "issue should mention 'transcript'; got: \(report.issues)")
        // Other items still copied
        XCTAssertEqual(try read(to, "grove/usage/\(id).json"), "usage\n",
                       "usage file should still be copied despite missing transcript")
    }

    /// 4. Idempotent — second run skips everything (no overwrites, no errors).
    func testCopySessionDataIdempotent() throws {
        let root = try Fixture.tempDir("migrate-idempotent")
        let from = root.appendingPathComponent("from")
        let to = root.appendingPathComponent("to")
        let cwd = "/Users/alice/myproject"
        let id = "aaaaaaaa-bbbb-cccc-dddd-111111111111"
        let mangled = ClaudeService.mangle(cwd)

        try write("transcript\n", at: from, "projects/\(mangled)/\(id).jsonl")
        try write("usage\n",      at: from, "grove/usage/\(id).json")

        let args = (sessionId: id, cwd: cwd,
                    fromConfigDir: from.path, toConfigDir: to.path,
                    mirrorRoot: nil as String?, fromAccountKey: "key")

        let first = SessionMigration.copySessionData(
            sessionId: args.sessionId, cwd: args.cwd,
            fromConfigDir: args.fromConfigDir, toConfigDir: args.toConfigDir,
            mirrorRoot: args.mirrorRoot, fromAccountKey: args.fromAccountKey
        )
        let targetAfterFirst = try snapshot(to)

        let second = SessionMigration.copySessionData(
            sessionId: args.sessionId, cwd: args.cwd,
            fromConfigDir: args.fromConfigDir, toConfigDir: args.toConfigDir,
            mirrorRoot: args.mirrorRoot, fromAccountKey: args.fromAccountKey
        )

        XCTAssertTrue(second.issues.isEmpty, "second run should have no issues: \(second.issues)")
        XCTAssertFalse(second.skipped.isEmpty, "second run should report skipped items")
        XCTAssertTrue(second.copied.isEmpty, "second run must copy nothing")
        XCTAssertEqual(try snapshot(to), targetAfterFirst, "target content must not change on second run")
        _ = first  // suppress unused-result warning
    }

    /// 5. memory merge non-destructive — existing target file NOT clobbered; new file added.
    func testCopySessionDataMemoryMergeNonDestructive() throws {
        let root = try Fixture.tempDir("migrate-memory-merge")
        let from = root.appendingPathComponent("from")
        let to = root.appendingPathComponent("to")
        let cwd = "/Users/alice/myproject"
        let id = "aaaaaaaa-bbbb-cccc-dddd-222222222222"
        let mangled = ClaudeService.mangle(cwd)

        // Source has EXISTING.md + NEW.md
        try write("source version\n", at: from, "projects/\(mangled)/memory/EXISTING.md")
        try write("new content\n",    at: from, "projects/\(mangled)/memory/NEW.md")
        try write("transcript\n",     at: from, "projects/\(mangled)/\(id).jsonl")

        // Target already has EXISTING.md with different content
        try write("target version\n", at: to, "projects/\(mangled)/memory/EXISTING.md")

        _ = SessionMigration.copySessionData(
            sessionId: id, cwd: cwd,
            fromConfigDir: from.path, toConfigDir: to.path,
            mirrorRoot: nil, fromAccountKey: "key"
        )

        XCTAssertEqual(try read(to, "projects/\(mangled)/memory/EXISTING.md"), "target version\n",
                       "existing target memory file must NOT be clobbered")
        XCTAssertEqual(try read(to, "projects/\(mangled)/memory/NEW.md"), "new content\n",
                       "new source memory file must be added to target")
    }

    /// 6. Non-destructive — source dir tree is byte-identical before and after.
    func testCopySessionDataSourceIsNonDestructive() throws {
        let root = try Fixture.tempDir("migrate-nondestructive")
        let from = root.appendingPathComponent("from")
        let to = root.appendingPathComponent("to")
        let cwd = "/Users/alice/myproject"
        let id = "aaaaaaaa-bbbb-cccc-dddd-333333333333"
        let mangled = ClaudeService.mangle(cwd)

        try write("transcript\n",  at: from, "projects/\(mangled)/\(id).jsonl")
        try write("subagent\n",    at: from, "projects/\(mangled)/\(id)/subagents/s.jsonl")
        try write("memory\n",      at: from, "projects/\(mangled)/memory/MEMORY.md")
        try write("file-hist\n",   at: from, "file-history/\(id)/f.txt")
        try write("task\n",        at: from, "tasks/\(id)/t.json")
        try write("usage\n",       at: from, "grove/usage/\(id).json")

        let sourceBefore = try snapshot(from)

        _ = SessionMigration.copySessionData(
            sessionId: id, cwd: cwd,
            fromConfigDir: from.path, toConfigDir: to.path,
            mirrorRoot: nil, fromAccountKey: "key"
        )

        XCTAssertEqual(try snapshot(from), sourceBefore,
                       "source must be identical after copy — nothing moved, deleted, or modified")
    }
}
