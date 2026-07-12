import XCTest
import GroveCore

final class UsageConfigTests: XCTestCase {
    // Old configs predate the whole usage block + the new account/project fields.
    func testOldJSONDecodesWithUsageDefaultsAndNilModelEffort() throws {
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
        // usage block absent -> defaults.
        XCTAssertEqual(decoded.usage, UsageSettings())
        XCTAssertEqual(decoded.usage.refreshSeconds, 15)
        XCTAssertTrue(decoded.usage.oauthLiveEnabled, "absent oauthLiveEnabled defaults to true after Phase 5C-fix")
        // account fields absent -> false / nil.
        XCTAssertEqual(decoded.accounts.map(\.monitoring), [false, false])
        XCTAssertEqual(decoded.accounts.map(\.savedStatusline), [nil, nil])
        XCTAssertEqual(decoded.accounts.map(\.defaultModel), [nil, nil])
        XCTAssertEqual(decoded.accounts.map(\.defaultEffort), [nil, nil])
        // project fields absent -> nil.
        XCTAssertNil(decoded.projects[0].defaultModel)
        XCTAssertNil(decoded.projects[0].defaultEffort)
    }

    func testUsageSettingsRoundTrips() throws {
        let s = UsageSettings(refreshSeconds: 30, oauthLiveEnabled: true)
        let decoded = try JSONDecoder().decode(UsageSettings.self,
                                               from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
    }

    func testAccountModelEffortMonitoringRoundTrip() throws {
        var a = AccountConfig(name: "work", configDir: "~/.claude-accounts/work")
        a.monitoring = true
        a.savedStatusline = "~/.claude/statusline-command.sh"
        a.defaultModel = "claude-opus-4-6"
        a.defaultEffort = "high"
        let decoded = try JSONDecoder().decode(AccountConfig.self,
                                               from: JSONEncoder().encode(a))
        XCTAssertEqual(decoded, a)
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

    func testDefaultConfigHasDefaultUsageBlock() {
        XCTAssertEqual(GroveConfig.defaultConfig.usage, UsageSettings())
    }

    func testNewAccountDefaultsAreInert() {
        let a = AccountConfig(name: "x", configDir: "~/x")
        XCTAssertFalse(a.monitoring)
        XCTAssertNil(a.savedStatusline)
        XCTAssertNil(a.defaultModel)
        XCTAssertNil(a.defaultEffort)
    }
}
