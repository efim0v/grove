import XCTest
import GroveCore

final class SharedStoreConfigTests: XCTestCase {
    // Old configs predate sharedStore; decoding must succeed with false.
    func testSharedStoreDecodesToFalseWhenAbsentFromOldJSON() throws {
        let json = """
        {
          "version": 1,
          "workspacesRootTemplate": "~/Workspaces/{project}",
          "projects": [],
          "accounts": [
            { "name": "default", "configDir": "~/.claude" },
            { "name": "work", "configDir": "~/.claude-accounts/work" }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(GroveConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.accounts.map(\.sharedStore), [false, false],
                       "absent sharedStore key decodes to false")
    }

    func testSharedStoreRoundTrips() throws {
        var account = AccountConfig(name: "work", configDir: "~/.claude-accounts/work")
        account.sharedStore = true
        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(AccountConfig.self, from: data)
        XCTAssertTrue(decoded.sharedStore)
        XCTAssertEqual(decoded, account)
    }

    func testSharedStoreDefaultsFalseOnNewAccount() {
        XCTAssertFalse(AccountConfig(name: "x", configDir: "~/.claude-accounts/x").sharedStore)
    }

    // The default/canonical account is implicitly canonical — sharedStore stays false.
    func testDefaultConfigAccountIsNotMarkedShared() {
        XCTAssertEqual(GroveConfig.defaultConfig.accounts.map(\.sharedStore), [false])
    }
}
