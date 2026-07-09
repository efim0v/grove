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
}
