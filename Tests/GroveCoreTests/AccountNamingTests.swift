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

    /// Two config dirs signed in to the same login are ONE account: the folder Claude
    /// Code used most recently launches it, the other becomes an alias read for its
    /// sessions; the absorbed entry's name maps to the survivor's.
    func testTwoDirsOfOneLoginMergeIntoOneAccountWithTheFresherDirPrimary() {
        var stale = account("me@icloud.com", "~/.claude-accounts/me@icloud.com"); stale.sharedStore = true
        let fresh = account("work-account", "~/.claude-accounts/work-account")
        let emails = ["work-account": "me@icloud.com", "me@icloud.com": "me@icloud.com"]
        let merge = AccountNaming.merged(accounts: [stale, fresh], emailByName: emails,
                                         activityByName: ["me@icloud.com": Date(timeIntervalSince1970: 100),
                                                          "work-account": Date(timeIntervalSince1970: 200)])
        XCTAssertEqual(merge.accounts.count, 1)
        let survivor = merge.accounts[0]
        XCTAssertEqual(survivor.name, "work-account", "the merge keeps the primary's name; the rename pass turns it into the email")
        XCTAssertEqual(survivor.configDir, "~/.claude-accounts/work-account")
        XCTAssertEqual(survivor.aliasDirs, ["~/.claude-accounts/me@icloud.com"])
        XCTAssertTrue(survivor.sharedStore, "a flag either dir had, the account has")
        XCTAssertEqual(merge.renames, ["me@icloud.com": "work-account"])
        // Then the rename pass: the survivor takes the email, now free.
        let renames = AccountNaming.renames(accounts: merge.accounts, emailByName: emails)
        XCTAssertEqual(renames, ["work-account": "me@icloud.com"])
        // No activity known at all: the earlier entry wins.
        let tie = AccountNaming.merged(accounts: [stale, fresh], emailByName: emails)
        XCTAssertEqual(tie.accounts[0].name, "me@icloud.com")
        XCTAssertEqual(tie.accounts[0].aliasDirs, ["~/.claude-accounts/work-account"])
    }

    func testUniqueNameFallsBackToTheFolderThenACounter() {
        XCTAssertEqual(AccountNaming.uniqueName(email: "x@y", folder: "old", taken: ["x@y"]), "x@y (old)")
        XCTAssertEqual(AccountNaming.uniqueName(email: "x@y", folder: "x@y", taken: ["x@y"]), "x@y (2)")
        XCTAssertEqual(AccountNaming.uniqueName(email: "x@y", folder: "x@y", taken: ["x@y", "x@y (2)"]), "x@y (3)")
        XCTAssertEqual(AccountNaming.uniqueName(email: "x@y", folder: "old", taken: ["x@y", "x@y (old)"]), "x@y (2)")
    }

    func testNothingToRenameIsEmpty() {
        let accounts = [account("me@gmail.com", "~/.claude"), account("no-identity", "~/x")]
        XCTAssertEqual(AccountNaming.renames(accounts: accounts, emailByName: ["me@gmail.com": "me@gmail.com"]), [:])
    }
}
