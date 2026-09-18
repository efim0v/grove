import XCTest
import GroveCore

final class AccountNamingTests: XCTestCase {
    private func account(_ name: String, _ dir: String) -> AccountConfig { AccountConfig(name: name, configDir: dir) }

    func testRenamesFolderNamesToEmailsAndMovesProjectDefaults() {
        var project = ProjectConfig(name: "p", path: "/p")
        project.defaultAccount = "default"
        let config = GroveConfig(version: 1, workspacesRootTemplate: "~/W/{project}", projects: [project],
                                 accounts: [account("default", "~/.claude"),
                                            account("work", "~/.claude-accounts/work"),
                                            account("offline", "~/.claude-accounts/offline")])
        let renames = AccountNaming.renames(accounts: config.accounts,
                                            emailByName: ["default": "me@gmail.com", "work": "me@corp.com"])
        XCTAssertEqual(renames, ["default": "me@gmail.com", "work": "me@corp.com"])
        let renamed = config.renamingAccounts(renames)
        XCTAssertEqual(renamed.accounts.map(\.name), ["me@gmail.com", "me@corp.com", "offline"])
        XCTAssertEqual(renamed.accounts[0].configDir, "~/.claude", "only the name changes")
        XCTAssertEqual(renamed.projects[0].defaultAccount, "me@gmail.com")
    }

    /// Two config dirs signed in to the same account: the one already named by the
    /// email keeps it, the other is told apart by its folder.
    func testASecondDirOfTheSameAccountIsToldApartByItsFolder() {
        let accounts = [account("work-account", "~/.claude-accounts/work-account"),
                        account("me@icloud.com", "~/.claude-accounts/me@icloud.com")]
        let renames = AccountNaming.renames(accounts: accounts,
                                            emailByName: ["work-account": "me@icloud.com", "me@icloud.com": "me@icloud.com"])
        XCTAssertEqual(renames, ["work-account": "me@icloud.com (work-account)"])
        XCTAssertEqual(AccountNaming.uniqueName(email: "x@y", folder: "x@y", taken: ["x@y"]), "x@y (2)")
        XCTAssertEqual(AccountNaming.uniqueName(email: "x@y", folder: "x@y", taken: ["x@y", "x@y (2)"]), "x@y (3)")
        XCTAssertEqual(AccountNaming.uniqueName(email: "x@y", folder: "old", taken: ["x@y", "x@y (old)"]), "x@y (2)")
    }

    func testNothingToRenameIsEmpty() {
        let accounts = [account("me@gmail.com", "~/.claude"), account("no-identity", "~/x")]
        XCTAssertEqual(AccountNaming.renames(accounts: accounts, emailByName: ["me@gmail.com": "me@gmail.com"]), [:])
    }
}
