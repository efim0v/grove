import XCTest
import GroveCore

final class UsageConfigTests: XCTestCase {
    // Old configs predate the account/project model/effort fields.
    func testOldJSONDecodesWithNilModelEffort() throws {
        let json = """
        {
          "version": 1,
          "workspacesRootTemplate": "~/Workspaces/{project}",
          "projects": [
            { "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "name": "p", "path": "~/p",
              "branchTemplate": "feat/{name}", "baseBranchOverrides": {},
              "postCreateHooks": {}, "excludedRepos": [], "scanDepth": 3 }
          ],
          "accounts": [
            { "name": "default", "configDir": "~/.claude" },
            { "name": "work", "configDir": "~/.claude-accounts/work" }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(GroveConfig.self, from: Data(json.utf8))
        // account fields absent -> false / nil.
        XCTAssertEqual(decoded.accounts.map(\.monitoring), [false, false])
        XCTAssertEqual(decoded.accounts.map(\.savedStatusline), [nil, nil])
        XCTAssertEqual(decoded.accounts.map(\.defaultModel), [nil, nil])
        XCTAssertEqual(decoded.accounts.map(\.defaultEffort), [nil, nil])
        // project fields absent -> nil.
        XCTAssertNil(decoded.projects[0].defaultModel)
        XCTAssertNil(decoded.projects[0].defaultEffort)
    }

    /// A config.json written while Grove still polled limits carries a `usage`
    /// block. It is nobody's now (Brow keeps its own settings) and must decode as
    /// an unknown key — never fail the whole config.
    func testLegacyUsageBlockIsIgnored() throws {
        let json = #"{"version":1,"workspacesRootTemplate":"~/W/{project}","projects":[],"accounts":[],"usage":{"refreshSeconds":30,"oauthLiveEnabled":false}}"#
        let decoded = try JSONDecoder().decode(GroveConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertTrue(decoded.accounts.isEmpty)
        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(reencoded.contains("oauthLiveEnabled"), "the block is dropped on the next write")
    }

    func testAccountModelEffortMonitoringRoundTrip() throws {
        var a = AccountConfig(name: "work", configDir: "~/.claude-accounts/work")
        a.monitoring = true
        a.savedStatusline = "~/.claude/statusline-command.sh"
        a.defaultModel = "claude-opus-4-6"
        a.defaultEffort = "high"
        a.aliasDirs = ["~/.claude-accounts/work-old"]
        let decoded = try JSONDecoder().decode(AccountConfig.self,
                                               from: JSONEncoder().encode(a))
        XCTAssertEqual(decoded, a)
        XCTAssertEqual(decoded.allConfigDirs, ["~/.claude-accounts/work", "~/.claude-accounts/work-old"])
        XCTAssertEqual(decoded.dirVariants.map(\.configDir), decoded.allConfigDirs)
        XCTAssertTrue(decoded.dirVariants.allSatisfy { $0.aliasDirs.isEmpty && $0.name == "work" })
    }

    func testProjectModelEffortRoundTrip() throws {
        var p = ProjectConfig(name: "p", path: "/p")
        p.defaultModel = "claude-sonnet-4-6"
        p.defaultEffort = "medium"
        let decoded = try JSONDecoder().decode(ProjectConfig.self,
                                               from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.defaultModel, "claude-sonnet-4-6")
        XCTAssertEqual(decoded.defaultEffort, "medium")
    }

    func testNewAccountDefaultsAreInert() {
        let a = AccountConfig(name: "x", configDir: "~/x")
        XCTAssertFalse(a.monitoring)
        XCTAssertNil(a.savedStatusline)
        XCTAssertNil(a.defaultModel)
        XCTAssertNil(a.defaultEffort)
    }
}
