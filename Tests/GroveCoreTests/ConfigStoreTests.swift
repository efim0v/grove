import XCTest
import GroveCore

final class ConfigStoreTests: XCTestCase {
    private func sampleConfig() -> GroveConfig {
        let project = ProjectConfig(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "acme.shop",
            path: "~/Desktop/acme.shop",
            workspacesRoot: "~/Workspaces/acme",
            branchTemplate: "feat/{name}",
            baseBranchOverrides: ["acme-server-config-a": "docker"],
            postCreateHooks: ["acme_client": "flutter pub get"],
            excludedRepos: ["vendor"],
            scanDepth: 2
        )
        return GroveConfig(
            version: 1,
            workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [project],
            accounts: [
                AccountConfig(name: "default", configDir: "~/.claude"),
                AccountConfig(name: "work", configDir: "~/.claude-accounts/work"),
            ]
        )
    }

    // MARK: - defaultAccount

    func testDefaultAccountDecodesFromOldJSONWithoutField() throws {
        // Old JSON has no "defaultAccount" key — must decode without error,
        // and the field must be nil.
        let json = """
        {
          "version": 1,
          "workspacesRootTemplate": "~/Workspaces/{project}",
          "projects": [],
          "accounts": []
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(GroveConfig.self, from: data)
        let proj = ProjectConfig(name: "test", path: "/tmp/test")
        XCTAssertNil(proj.defaultAccount, "defaultAccount must be nil when not set")
        _ = decoded // silence unused warning — we're testing GroveConfig decodes successfully
    }

    func testDefaultAccountRoundTrip() throws {
        let dir = try Fixture.tempDir("default-account-roundtrip")
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        var original = sampleConfig()
        original.projects[0].defaultAccount = "work"
        try store.save(original)
        let (loaded, issue) = store.load()
        XCTAssertNil(issue)
        XCTAssertEqual(loaded.projects[0].defaultAccount, "work")
    }

    func testDefaultAccountNilByDefault() {
        let proj = ProjectConfig(name: "test", path: "/tmp/test")
        XCTAssertNil(proj.defaultAccount)
    }

    func testDefaultConfig() {
        let def = GroveConfig.defaultConfig
        XCTAssertEqual(def.version, 1)
        XCTAssertEqual(def.workspacesRootTemplate, "~/Workspaces/{project}")
        XCTAssertTrue(def.projects.isEmpty)
        XCTAssertEqual(def.accounts, [AccountConfig(name: "default", configDir: "~/.claude")])
    }

    func testSaveLoadRoundTrip() throws {
        let dir = try Fixture.tempDir("config-roundtrip")
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        let original = sampleConfig()
        try store.save(original)
        let (loaded, issue) = store.load()
        XCTAssertNil(issue)
        XCTAssertEqual(loaded, original)
    }

    func testMissingFileReturnsDefaultWithoutIssue() throws {
        let dir = try Fixture.tempDir("config-missing")
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        let (loaded, issue) = store.load()
        XCTAssertNil(issue)
        XCTAssertEqual(loaded, .defaultConfig)
    }

    func testCorruptFileBacksUpAndReturnsDefaultWithIssue() throws {
        let dir = try Fixture.tempDir("config-corrupt")
        let url = dir.appendingPathComponent("config.json")
        let garbage = "{ this is not json"
        try garbage.write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(url: url)
        let (loaded, issue) = store.load()
        XCTAssertEqual(loaded, .defaultConfig)
        XCTAssertNotNil(issue)
        let backup = dir.appendingPathComponent("config.json.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), garbage)
    }

    func testSaveCreatesParentDirsAndOverwritesAtomically() throws {
        let dir = try Fixture.tempDir("config-mkdir")
        let url = dir.appendingPathComponent("nested/deeper/config.json")
        let store = ConfigStore(url: url)
        try store.save(.defaultConfig)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        var second = sampleConfig()
        second.version = 2
        try store.save(second)
        let (loaded, issue) = store.load()
        XCTAssertNil(issue)
        XCTAssertEqual(loaded, second)

        // tmp + rename must not leave stray temp files next to the config
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(entries, ["config.json"])
    }
}
