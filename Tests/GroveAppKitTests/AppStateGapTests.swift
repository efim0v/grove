import XCTest
import GroveCore
@testable import GroveAppKit

@MainActor
final class AppStateGapTests: XCTestCase {
    private var configURL: URL!
    private var root: URL!

    override func setUp() async throws {
        root = try FixtureLite.tempDir("appstate-gap")
        configURL = root.appendingPathComponent("config.json")
    }

    private func state(_ runner: ScriptedRunner = ScriptedRunner(responses: ["ping": .ok("PONG")])) -> AppState {
        let s = AppState(configStore: ConfigStore(url: configURL))
        s.cmuxOverride = stubbedCmux(runner)
        s.canonicalDirOverride = root.appendingPathComponent("canonical").path
        return s
    }

    func testProjectCrudModelEffortAndSelection() {
        let s = state()
        s.addProject(at: "/tmp/grove-demo")
        let id = s.selectedProjectID!
        XCTAssertEqual(s.selectedProject?.name, "grove-demo")
        s.setProjectModel(projectID: id, model: "claude-opus-4-8")
        s.setProjectEffort(projectID: id, effort: "high")
        XCTAssertEqual(s.selectedProject?.defaultModel, "claude-opus-4-8")
        XCTAssertEqual(s.selectedProject?.defaultEffort, "high")
        s.setProjectModel(projectID: id, model: "")     // empty clears
        s.setProjectEffort(projectID: id, effort: "")
        XCTAssertNil(s.selectedProject?.defaultModel)
        XCTAssertNil(s.selectedProject?.defaultEffort)
        s.updateProject(ProjectConfig(name: "ghost", path: "/x"))   // unknown id -> no-op
        XCTAssertEqual(s.config.projects.count, 1)
        s.removeProject(id: id)
        XCTAssertTrue(s.config.projects.isEmpty)
        XCTAssertNil(s.selectedProjectID)
    }

    func testAccountCrudRejectsDuplicates() {
        let s = state()
        // addAccount auto-installs a statusline (Phase 5A); keep its dir + script writes
        // inside temp dirs, never the real ~/.claude-accounts / ~/Library.
        s.accountsRootOverride = root.appendingPathComponent("accts").path
        s.statuslineScriptDirOverride = root.appendingPathComponent("bin-crud").path
        let initial = s.config.accounts.count
        s.addAccount(name: "work")
        XCTAssertTrue(s.config.accounts.contains { $0.name == "work" })
        XCTAssertEqual(s.config.accounts.count, initial + 1)
        s.addAccount(name: "work")        // duplicate
        XCTAssertNotNil(s.actionError)
        XCTAssertEqual(s.config.accounts.count, initial + 1, "duplicate not added")
        s.removeAccount(name: "work")
        XCTAssertFalse(s.config.accounts.contains { $0.name == "work" })
    }

    func testWorkspacesRootTemplatePersists() {
        let s = state()
        s.setWorkspacesRootTemplate("~/Code/{project}")
        XCTAssertEqual(s.config.workspacesRootTemplate, "~/Code/{project}")
    }

    func testGoToCmuxAndOpenShellRecordCalls() async {
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let s = state(runner)
        await s.goToCmux(CmuxWorkspace(id: "ws-1", title: "t", currentDirectory: "/a"))
        XCTAssertEqual(runner.calls(startingWith: "select-workspace").first?.args,
                       ["select-workspace", "--workspace", "ws-1"])
        await s.openCmuxShell(cwd: "/a", title: "shell")
        XCTAssertEqual(runner.calls(startingWith: "new-workspace").count, 1)
    }

    func testShortModelNameStripsClaudePrefix() {
        XCTAssertEqual(shortModelName("claude-sonnet-4-6"), "sonnet-4-6")
        XCTAssertEqual(shortModelName("claude-opus-4-8"), "opus-4-8")
        XCTAssertEqual(shortModelName("gpt-x"), "gpt-x")       // untouched
    }

    /// Phase 5A launch reconcile: auto-installs the statusline wrapper for every
    /// configured account that is not yet monitored (e.g. accounts created before 5A,
    /// or an icloud account that never had monitoring enabled), preserving each
    /// account's original command. Accounts already monitored are left untouched, so a
    /// user who explicitly disabled monitoring is not re-enabled on the next launch.
    /// reconcileMonitoring fires I/O off-main (Task.detached), so we await completion.
    func testReconcileMonitoringInstallsForUnmonitoredAccountsOnly() async throws {
        let s = state()
        let binDir = root.appendingPathComponent("reconcile-bin")
        s.statuslineScriptDirOverride = binDir.path
        let dirA = root.appendingPathComponent("recon-a")   // never monitored
        let dirB = root.appendingPathComponent("recon-b")   // already monitored
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        let originalA = "/bin/echo status-a"
        try #"{"statusLine":{"type":"command","command":"\#(originalA)"}}"#
            .write(to: dirA.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let originalB = "/bin/echo status-b"
        try #"{"statusLine":{"type":"command","command":"\#(originalB)"}}"#
            .write(to: dirB.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        s.config.accounts = [
            AccountConfig(name: "a", configDir: dirA.path),
            AccountConfig(name: "b", configDir: dirB.path, monitoring: true),
        ]

        s.reconcileMonitoring()

        // reconcileMonitoring dispatches I/O to a Task.detached; yield until task completes.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            await Task.yield()
            if s.config.accounts.first(where: { $0.name == "a" })?.monitoring == true { break }
        }

        XCTAssertNil(s.actionError)
        // Account a: installed, original preserved, marked monitored.
        let a = try XCTUnwrap(s.config.accounts.first { $0.name == "a" })
        XCTAssertEqual(a.monitoring, true)
        XCTAssertEqual(a.savedStatusline, originalA)
        let aObj = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dirA.appendingPathComponent("settings.json"))) as? [String: Any]
        XCTAssertTrue(((aObj?["statusLine"] as? [String: Any])?["command"] as? String)?
            .contains("grove-statusline-") == true)
        // Account b: already monitored → left untouched (settings.json still the original).
        let bObj = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dirB.appendingPathComponent("settings.json"))) as? [String: Any]
        XCTAssertEqual((bObj?["statusLine"] as? [String: Any])?["command"] as? String, originalB,
                       "an already-monitored account must not be re-installed by reconcile")
    }

    /// A fresh account (no statusline of its own — every account Brow's one-click
    /// sign-in creates) must come out of the launch reconcile MONITORED, with no
    /// original to save. It used to be re-installed on every launch instead.
    func testReconcileMonitoringMarksAnAccountWithNoPriorStatusline() async throws {
        let s = state()
        s.statuslineScriptDirOverride = root.appendingPathComponent("reconcile-bin-2").path
        let dir = root.appendingPathComponent("recon-fresh")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        s.config.accounts = [AccountConfig(name: "fresh", configDir: dir.path)]

        s.reconcileMonitoring()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            await Task.yield()
            if s.config.accounts.first?.monitoring == true { break }
        }

        let fresh = try XCTUnwrap(s.config.accounts.first)
        XCTAssertTrue(fresh.monitoring, "installed → monitored, even with nothing to save")
        XCTAssertNil(fresh.savedStatusline)
        let obj = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("settings.json"))) as? [String: Any]
        XCTAssertTrue(((obj?["statusLine"] as? [String: Any])?["command"] as? String)?
            .contains("grove-statusline-") == true)
    }

    /// The folders Brow's sign-in creates (`~/.claude-accounts/account-1`) join the
    /// list at launch, named by their email; a folder Grove already knows, or one
    /// nobody is signed in to, is left alone.
    func testDiscoverAccountDirsAddsSignedInFoldersNamedByEmail() throws {
        let s = state()
        let accountsRoot = root.appendingPathComponent("accounts-root")
        s.accountsRootOverride = accountsRoot.path
        let fm = FileManager.default
        for (folder, email) in [("account-1", "one@example.com"), ("account-2", "two@example.com"), ("empty", nil)] {
            let dir = accountsRoot.appendingPathComponent(folder)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let email {
                try #"{"oauthAccount":{"emailAddress":"\#(email)","organizationUuid":"org-\#(folder)"}}"#
                    .write(to: dir.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
            }
        }
        s.config.accounts = [AccountConfig(name: "one@example.com", configDir: accountsRoot.appendingPathComponent("account-1").path)]

        XCTAssertTrue(s.discoverAccountDirs())
        XCTAssertEqual(s.config.accounts.map(\.name), ["one@example.com", "two@example.com"])
        XCTAssertEqual(s.config.accounts[1].configDir, accountsRoot.appendingPathComponent("account-2").path)
        XCTAssertFalse(s.discoverAccountDirs(), "idempotent")

        // A second folder signed in as one@example.com joins that account as an alias.
        let again = accountsRoot.appendingPathComponent("account-3")
        try fm.createDirectory(at: again, withIntermediateDirectories: true)
        try #"{"oauthAccount":{"emailAddress":"one@example.com","organizationUuid":"org-account-1"}}"#
            .write(to: again.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(s.discoverAccountDirs())
        XCTAssertEqual(s.config.accounts.map(\.name), ["one@example.com", "two@example.com"], "no third entry")
        XCTAssertEqual(s.config.accounts[0].aliasDirs, [again.path])
    }

    /// Once identities are read, folder names give way to emails — the project
    /// default follows — and the captures are re-keyed by the new names.
    func testReconcileAccountNamesRenamesToEmailsAfterIdentitiesAreRead() async throws {
        let s = state()
        let dirA = root.appendingPathComponent("named-a")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try #"{"oauthAccount":{"emailAddress":"a@example.com","organizationUuid":"org-a"}}"#
            .write(to: dirA.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        // A second folder signed in as the same login, used more recently.
        let dirA2 = root.appendingPathComponent("named-a2")
        try FileManager.default.createDirectory(at: dirA2, withIntermediateDirectories: true)
        try #"{"oauthAccount":{"emailAddress":"a@example.com","organizationUuid":"org-a"}}"#
            .write(to: dirA2.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                              ofItemAtPath: dirA.appendingPathComponent(".claude.json").path)
        s.config.accounts = [AccountConfig(name: "default", configDir: dirA.path),
                             AccountConfig(name: "twice", configDir: dirA2.path),
                             AccountConfig(name: "nameless", configDir: root.appendingPathComponent("named-b").path)]
        var project = ProjectConfig(name: "p", path: root.appendingPathComponent("p").path)
        project.defaultAccount = "default"
        s.config.projects = [project]

        XCTAssertFalse(s.reconcileAccountNames(), "nothing known yet")
        await s.refreshUsage(now: Date())
        XCTAssertTrue(s.reconcileAccountNames())
        XCTAssertEqual(s.config.accounts.map(\.name), ["a@example.com", "nameless"])
        XCTAssertEqual(s.config.accounts[0].configDir, dirA2.path, "the fresher folder launches the account")
        XCTAssertEqual(s.config.accounts[0].aliasDirs, [dirA.path])
        XCTAssertEqual(s.config.projects[0].defaultAccount, "a@example.com")
        XCTAssertFalse(s.reconcileAccountNames(), "settled")
        await s.refreshUsage(now: Date())
        XCTAssertNotNil(s.identityByAccount["a@example.com"], "captures and identities re-keyed")
    }

    func testInstallAndDisableMonitoringToggleFlag() throws {
        let s = state()
        s.statuslineScriptDirOverride = root.appendingPathComponent("bin").path
        let dir = root.appendingPathComponent("acct-claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        s.config.accounts = [AccountConfig(name: "work", configDir: dir.path)]
        s.installMonitoring(s.config.accounts[0])
        XCTAssertTrue(s.config.accounts[0].monitoring)
        s.disableMonitoring(s.config.accounts[0])
        XCTAssertFalse(s.config.accounts[0].monitoring)
    }

    /// FIX 1: reconcileMonitoring must NOT re-enable an explicitly-disabled account.
    /// An account with monitoring=false AND monitoringDisabledByUser=true is skipped.
    /// An account with monitoring=false AND monitoringDisabledByUser=false (never monitored) IS installed.
    /// reconcileMonitoring fires file I/O off-main (Task.detached), so we await completion.
    func testReconcileMonitoringDoesNotReEnableExplicitlyDisabledAccount() async throws {
        let s = state()
        let binDir = root.appendingPathComponent("fix1-bin")
        s.statuslineScriptDirOverride = binDir.path

        // Account A: never monitored (disabledByUser=false) — should be installed.
        let dirA = root.appendingPathComponent("fix1-a")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try #"{"statusLine":{"type":"command","command":"/bin/echo status-a"}}"#
            .write(to: dirA.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        // Account B: user explicitly disabled monitoring (disabledByUser=true) — must NOT be installed.
        let dirB = root.appendingPathComponent("fix1-b")
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        let originalB = "/bin/echo status-b"
        try #"{"statusLine":{"type":"command","command":"\#(originalB)"}}"#
            .write(to: dirB.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        s.config.accounts = [
            AccountConfig(name: "never-monitored", configDir: dirA.path,
                          monitoring: false, monitoringDisabledByUser: false),
            AccountConfig(name: "user-disabled", configDir: dirB.path,
                          monitoring: false, monitoringDisabledByUser: true),
        ]

        s.reconcileMonitoring()

        // reconcileMonitoring dispatches I/O to a Task.detached; yield back to run loop
        // long enough for the utility task + MainActor.run hop to complete.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            await Task.yield()
            if s.config.accounts.first(where: { $0.name == "never-monitored" })?.monitoring == true { break }
        }

        // Account A (never monitored): should be installed and marked monitored.
        let acctA = try XCTUnwrap(s.config.accounts.first { $0.name == "never-monitored" })
        XCTAssertTrue(acctA.monitoring, "never-monitored account should be auto-installed by reconcile")

        // Account B (user disabled): must NOT be re-enabled.
        let acctB = try XCTUnwrap(s.config.accounts.first { $0.name == "user-disabled" })
        XCTAssertFalse(acctB.monitoring, "explicitly-disabled account must not be re-enabled by reconcile")
        // settings.json for B must still contain the original command, not the grove wrapper.
        let bObj = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dirB.appendingPathComponent("settings.json"))) as? [String: Any]
        XCTAssertEqual((bObj?["statusLine"] as? [String: Any])?["command"] as? String, originalB,
                       "reconcile must not overwrite settings.json of an explicitly-disabled account")
    }

    /// FIX 1: disableMonitoring sets monitoringDisabledByUser=true; installMonitoring/enableMonitoring clears it.
    func testDisableMonitoringSetsDisabledByUserFlag() throws {
        let s = state()
        s.statuslineScriptDirOverride = root.appendingPathComponent("fix1-toggle-bin").path
        let dir = root.appendingPathComponent("fix1-toggle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        s.config.accounts = [AccountConfig(name: "work", configDir: dir.path)]

        // Install first so disableMonitoring has something to uninstall.
        s.installMonitoring(s.config.accounts[0])
        XCTAssertTrue(s.config.accounts[0].monitoring)
        XCTAssertFalse(s.config.accounts[0].monitoringDisabledByUser,
                       "install must clear monitoringDisabledByUser")

        // Disable: must set the flag.
        s.disableMonitoring(s.config.accounts[0])
        XCTAssertFalse(s.config.accounts[0].monitoring)
        XCTAssertTrue(s.config.accounts[0].monitoringDisabledByUser,
                      "disableMonitoring must set monitoringDisabledByUser=true")

        // Re-install via installMonitoring: must clear the flag.
        s.installMonitoring(s.config.accounts[0])
        XCTAssertTrue(s.config.accounts[0].monitoring)
        XCTAssertFalse(s.config.accounts[0].monitoringDisabledByUser,
                       "re-installing must clear monitoringDisabledByUser")
    }
}
