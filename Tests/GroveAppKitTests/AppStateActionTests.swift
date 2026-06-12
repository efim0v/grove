import XCTest
import GroveCore
@testable import GroveAppKit

@MainActor
final class AppStateActionTests: XCTestCase {
    private var root: URL!
    private var configURL: URL!

    /// Non-default account so launchCommand carries the CLAUDE_CONFIG_DIR prefix.
    private let account = AccountConfig(name: "work", configDir: "/tmp/grove-test-claude")

    override func setUp() async throws {
        root = try FixtureLite.tempDir("appstate-actions")
        configURL = root.appendingPathComponent("config.json")
    }

    /// Builds an AppState wired to the test runner/config. ALWAYS points
    /// canonicalDirOverride at a per-state temp dir so linking can never touch the
    /// real ~/.claude — tests that need a specific canonical dir re-point it after.
    private func makeState(runner: ScriptedRunner) -> AppState {
        let state = AppState(configStore: ConfigStore(url: configURL))
        state.cmuxOverride = stubbedCmux(runner)
        // Fail-safe: default the canonical store to a temp dir, NEVER $HOME/.claude.
        state.canonicalDirOverride = root.appendingPathComponent("canonical-default").path
        return state
    }

    // MARK: - launchClaude

    func testLaunchClaudeCreatesFocusedCmuxWorkspaceWithLaunchCommand() async throws {
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner: runner)
        // The claude binary resolves to an absolute path on this machine; the
        // launch command embeds it shell-quoted (PATH-independent by design).
        let claude = shellQuote(ClaudeService.claudeExecutable())

        await state.launchClaude(cwd: "/ws/feat-x", title: "feat-x", account: account, resume: nil)

        XCTAssertNil(state.actionError)
        let newCalls = runner.calls(startingWith: "new-workspace")
        XCTAssertEqual(newCalls.count, 1)
        XCTAssertEqual(newCalls[0].args,
                       ["new-workspace", "--name", "feat-x", "--cwd", "/ws/feat-x",
                        "--command", "CLAUDE_CONFIG_DIR='/tmp/grove-test-claude' \(claude)",
                        "--focus", "true"])
        // focus=true triggers app activation through the SAME stub runner — never for real
        XCTAssertEqual(runner.calls.filter { $0.executable == "/usr/bin/open" }.count, 1)
    }

    func testLaunchClaudeResumeAppendsQuotedSessionId() async throws {
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner: runner)
        let claude = shellQuote(ClaudeService.claudeExecutable())

        await state.launchClaude(cwd: "/ws/feat-x", title: "feat-x", account: account,
                                 resume: "abc-123")

        let args = try XCTUnwrap(runner.calls(startingWith: "new-workspace").first).args
        let commandIndex = try XCTUnwrap(args.firstIndex(of: "--command"))
        XCTAssertTrue(args[commandIndex + 1].hasSuffix(" \(claude) --resume 'abc-123'"),
                      "got: \(args[commandIndex + 1])")
    }

    func testLaunchClaudeFailureLandsInActionError() async throws {
        let runner = ScriptedRunner(responses: [
            "ping": .ok("PONG"),
            "new-workspace": .fail("no window"),
        ])
        let state = makeState(runner: runner)

        await state.launchClaude(cwd: "/ws/feat-x", title: "feat-x", account: account, resume: nil)

        let error = try XCTUnwrap(state.actionError)
        XCTAssertTrue(error.contains("new-workspace"), "got: \(error)")
    }

    func testLaunchClaudePassesModelAndEffortIntoTheCommand() async throws {
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner: runner)
        await state.launchClaude(cwd: "/ws/x", title: "X", account: account,
                                 resume: nil, model: "claude-opus-4-6", effort: "high")
        let call = try XCTUnwrap(runner.calls(startingWith: "new-workspace").first)
        let commandIndex = try XCTUnwrap(call.args.firstIndex(of: "--command"))
        let command = call.args[commandIndex + 1]
        XCTAssertTrue(command.contains("--model 'claude-opus-4-6'"), command)
        XCTAssertTrue(command.contains("--effort 'high'"), command)
    }

    /// resumeSession applies the project's default model/effort (project beats
    /// account default). The session's project is resolved by cwd prefix.
    func testResumeSessionAppliesProjectDefaultModelEffort() async throws {
        var project = ProjectConfig(name: "p", path: "/proj")
        project.workspacesRoot = "/ws"
        project.defaultModel = "claude-sonnet-4-6"
        project.defaultEffort = "medium"
        try ConfigStore(url: configURL).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [project], accounts: [account]))
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner: runner)
        state.selectedProjectID = project.id
        let session = ClaudeSession(id: "s1", cwd: "/ws/feat-x", title: "T",
                                    lastActivity: Date(), accountName: "work", gitBranch: nil)
        await state.resumeSession(session, as: account)   // same account -> no link
        let call = try XCTUnwrap(runner.calls(startingWith: "new-workspace").first)
        let commandIndex = try XCTUnwrap(call.args.firstIndex(of: "--command"))
        XCTAssertTrue(call.args[commandIndex + 1].contains("--model 'claude-sonnet-4-6'"))
        XCTAssertTrue(call.args[commandIndex + 1].contains("--effort 'medium'"))
    }

    // MARK: - goToCmux

    func testGoToCmuxSelectsWorkspaceAndActivates() async {
        let runner = ScriptedRunner(responses: [:])
        let state = makeState(runner: runner)

        await state.goToCmux(CmuxWorkspace(id: "ws-7", title: "t", currentDirectory: "/x"))

        XCTAssertNil(state.actionError)
        XCTAssertEqual(runner.calls(startingWith: "select-workspace").first?.args,
                       ["select-workspace", "--workspace", "ws-7"])
    }

    func testGoToCmuxFailureLandsInActionError() async {
        let runner = ScriptedRunner(responses: ["select-workspace": .fail("gone")])
        let state = makeState(runner: runner)

        await state.goToCmux(CmuxWorkspace(id: "ws-7", title: "t", currentDirectory: "/x"))

        XCTAssertNotNil(state.actionError)
    }

    // MARK: - goToSession

    func testGoToSessionPrefersHookMappedWorkspace() async throws {
        let runner = ScriptedRunner(responses: [:])
        let state = makeState(runner: runner)
        let hookFile = root.appendingPathComponent("hooks.json")
        try Data(#"{"sess-1": {"workspaceId": "ws-42", "cwd": "/ws/feat-x"}}"#.utf8)
            .write(to: hookFile)
        state.cmuxHookFile = hookFile.path
        let session = ClaudeSession(id: "sess-1", cwd: "/ws/feat-x", title: nil,
                                    lastActivity: Date(), accountName: "work", gitBranch: nil)

        await state.goToSession(session, fallbackCwd: "/ws/feat-x", fallbackTitle: "feat-x",
                                account: account)

        XCTAssertEqual(runner.calls(startingWith: "select-workspace").first?.args,
                       ["select-workspace", "--workspace", "ws-42"])
        XCTAssertTrue(runner.calls(startingWith: "new-workspace").isEmpty)
        XCTAssertNil(state.actionError)
    }

    func testGoToSessionWithoutMappingResumesInNewWorkspace() async throws {
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner: runner)
        state.cmuxHookFile = root.appendingPathComponent("no-such-hooks.json").path
        let session = ClaudeSession(id: "sess-9", cwd: "/ws/feat-x", title: nil,
                                    lastActivity: Date(), accountName: "work", gitBranch: nil)

        await state.goToSession(session, fallbackCwd: "/ws/feat-x", fallbackTitle: "feat-x",
                                account: account)

        XCTAssertTrue(runner.calls(startingWith: "select-workspace").isEmpty)
        let args = try XCTUnwrap(runner.calls(startingWith: "new-workspace").first).args
        let cwdIndex = try XCTUnwrap(args.firstIndex(of: "--cwd"))
        XCTAssertEqual(args[cwdIndex + 1], "/ws/feat-x")
        let commandIndex = try XCTUnwrap(args.firstIndex(of: "--command"))
        XCTAssertTrue(args[commandIndex + 1].contains("--resume 'sess-9'"))
    }

    /// A `.go` row resolved only via the cwd-match path (no hook entry) carries
    /// the matched cmux workspace id; goToSession must selectWorkspace it
    /// directly, NOT relaunch --resume in a fresh workspace (issue 2).
    func testGoToSessionWithExplicitWorkspaceIdSelectsItWithoutHookFile() async throws {
        let runner = ScriptedRunner(responses: [:])
        let state = makeState(runner: runner)
        state.cmuxHookFile = root.appendingPathComponent("no-such-hooks.json").path
        let session = ClaudeSession(id: "sess-cwd", cwd: "/ws/feat-x", title: nil,
                                    lastActivity: Date(), accountName: "work", gitBranch: nil)

        await state.goToSession(session, fallbackCwd: "/ws/feat-x", fallbackTitle: "feat-x",
                                account: account, workspaceId: "cw-cwd")

        XCTAssertEqual(runner.calls(startingWith: "select-workspace").first?.args,
                       ["select-workspace", "--workspace", "cw-cwd"])
        XCTAssertTrue(runner.calls(startingWith: "new-workspace").isEmpty,
                      "Go must jump to the matched workspace, not spawn a second writer")
        XCTAssertNil(state.actionError)
    }

    // MARK: - resumeSession (cross-account, feasibility verdict: FEASIBLE)

    /// Same-account resume links nothing and just launches --resume in the
    /// session's own cwd under its owning account.
    func testResumeSessionSameAccountLaunchesWithoutCopying() async throws {
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner: runner)
        let session = ClaudeSession(id: "sess-same", cwd: "/ws/feat-x", title: "Tidy up",
                                    lastActivity: Date(), accountName: "work", gitBranch: nil)

        await state.resumeSession(session, as: account)   // account.name == "work"

        XCTAssertNil(state.actionError)
        let args = try XCTUnwrap(runner.calls(startingWith: "new-workspace").first).args
        let cwdIndex = try XCTUnwrap(args.firstIndex(of: "--cwd"))
        XCTAssertEqual(args[cwdIndex + 1], "/ws/feat-x")
        let commandIndex = try XCTUnwrap(args.firstIndex(of: "--command"))
        XCTAssertTrue(args[commandIndex + 1].contains("--resume 'sess-same'"))
    }

    /// Cross-account resume LINKS both the owning and the target account into the
    /// canonical default (`~/.claude`) store, then launches --resume under the
    /// target's CLAUDE_CONFIG_DIR. No copy: the transcript physically lives in
    /// canonical and is visible to the target through the symlinked projects dir.
    func testResumeSessionCrossAccountLinksBothAccountsThenLaunchesUnderTarget() async throws {
        let home = NSHomeDirectory()
        let cwd = "/ws/feat-x"
        let id = "sess-cross"
        // Canonical = the default account at $HOME/.claude (the real canonical
        // path; we never write into it — the owner OWNS the transcript under it,
        // staged below in a temp dir we point configDir at). To keep tests off the
        // real ~/.claude, the default account's configDir is a TEMP dir we treat
        // as canonical, and AppState's canonical check matches on configDir, so we
        // make the default account point at a temp "canonical" dir.
        let canonicalDir = root.appendingPathComponent("canonical")   // default account dir
        let ownerDir = root.appendingPathComponent("acc-owner")        // owning, non-canonical
        let targetDir = root.appendingPathComponent("acc-target")      // target, non-canonical
        try FileManager.default.createDirectory(at: canonicalDir, withIntermediateDirectories: true)

        // The owning account holds the transcript at its projects/<mangled> path.
        let mangled = ClaudeService.mangle(cwd)
        let ownerProjects = ownerDir.appendingPathComponent("projects").appendingPathComponent(mangled)
        try FileManager.default.createDirectory(at: ownerProjects, withIntermediateDirectories: true)
        try "transcript".write(to: ownerProjects.appendingPathComponent("\(id).jsonl"),
                               atomically: true, encoding: .utf8)

        // Config: the canonical/default account FIRST (its configDir is treated as
        // canonical because AppState resolves canonical = the account whose expanded
        // configDir is the default account dir; see canonicalAccount). Mark it by
        // pointing the default account at canonicalDir via a test seam.
        let defaultAccount = AccountConfig(name: "default", configDir: canonicalDir.path)
        let owner = AccountConfig(name: "owner", configDir: ownerDir.path)
        let target = AccountConfig(name: "work", configDir: targetDir.path)
        try ConfigStore(url: configURL).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [], accounts: [defaultAccount, owner, target]))

        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner: runner)
        state.canonicalDirOverride = canonicalDir.path   // test seam: treat this as ~/.claude
        let session = ClaudeSession(id: id, cwd: cwd, title: "Tidy",
                                    lastActivity: Date(), accountName: "owner", gitBranch: nil)

        await state.resumeSession(session, as: target)

        XCTAssertNil(state.actionError)
        // Owner's wholesale dirs are symlinked into canonical.
        for name in SharedSessionStore.wholesaleDirs {
            let link = ownerDir.appendingPathComponent(name).path
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link),
                           canonicalDir.appendingPathComponent(name).path, "owner \(name)")
            let tlink = targetDir.appendingPathComponent(name).path
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: tlink),
                           canonicalDir.appendingPathComponent(name).path, "target \(name)")
        }
        // Owner's projects/<mangled> is symlinked; the transcript migrated into canonical.
        let ownerLink = ownerDir.appendingPathComponent("projects/\(mangled)").path
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: ownerLink),
                       canonicalDir.appendingPathComponent("projects/\(mangled)").path)
        XCTAssertEqual(try String(contentsOf: canonicalDir
            .appendingPathComponent("projects/\(mangled)/\(id).jsonl"), encoding: .utf8), "transcript")
        // Target's projects/<mangled> is a symlink into canonical → transcript visible.
        let targetLink = targetDir.appendingPathComponent("projects/\(mangled)").path
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: targetLink),
                       canonicalDir.appendingPathComponent("projects/\(mangled)").path)
        // Both accounts are now marked sharedStore in config.
        XCTAssertEqual(state.config.accounts.first { $0.name == "owner" }?.sharedStore, true)
        XCTAssertEqual(state.config.accounts.first { $0.name == "work" }?.sharedStore, true)
        XCTAssertEqual(state.config.accounts.first { $0.name == "default" }?.sharedStore, false,
                       "the canonical account is never marked shared")
        // Launched under the TARGET account's config dir with --resume.
        let args = try XCTUnwrap(runner.calls(startingWith: "new-workspace").first).args
        let commandIndex = try XCTUnwrap(args.firstIndex(of: "--command"))
        XCTAssertTrue(args[commandIndex + 1].contains("CLAUDE_CONFIG_DIR=\(shellQuote(targetDir.path))"))
        XCTAssertTrue(args[commandIndex + 1].contains("--resume '\(id)'"))
        _ = home
    }

    /// Cross-account resume when the owning account is no longer in config: we
    /// can't locate/link the transcript, so resuming would only surface "No
    /// conversation found". resumeSession must abort with an actionError and
    /// launch nothing.
    func testResumeSessionCrossAccountWithMissingOwnerSetsActionErrorAndDoesNotLaunch() async throws {
        let canonicalDir = root.appendingPathComponent("canonical-missing-owner")
        try FileManager.default.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
        let defaultAccount = AccountConfig(name: "default", configDir: canonicalDir.path)
        let target = AccountConfig(name: "work", configDir: root.appendingPathComponent("t").path)
        try ConfigStore(url: configURL).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [], accounts: [defaultAccount, target]))
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner: runner)
        state.canonicalDirOverride = canonicalDir.path
        let session = ClaudeSession(id: "sess-ghost", cwd: "/ws/feat-x", title: nil,
                                    lastActivity: Date(), accountName: "ghost", gitBranch: nil)

        await state.resumeSession(session, as: target)

        let error = try XCTUnwrap(state.actionError)
        XCTAssertTrue(error.contains("ghost"), "got: \(error)")
        XCTAssertTrue(runner.calls(startingWith: "new-workspace").isEmpty,
                      "no launch when the owning account can't be linked")
    }

    /// Cross-account resume with NO canonical/default account in config: sharing
    /// is impossible without a canonical `~/.claude`. Abort with a clear error,
    /// launch nothing.
    func testResumeSessionCrossAccountWithoutCanonicalAccountAborts() async throws {
        // Two non-canonical accounts, neither pointing at the canonical dir.
        let owner = AccountConfig(name: "owner", configDir: root.appendingPathComponent("o").path)
        let target = AccountConfig(name: "work", configDir: root.appendingPathComponent("t2").path)
        try ConfigStore(url: configURL).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [], accounts: [owner, target]))
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner: runner)
        state.canonicalDirOverride = root.appendingPathComponent("nonexistent-canonical").path
        let session = ClaudeSession(id: "sess-x", cwd: "/ws/feat-x", title: nil,
                                    lastActivity: Date(), accountName: "owner", gitBranch: nil)

        await state.resumeSession(session, as: target)

        let error = try XCTUnwrap(state.actionError)
        XCTAssertTrue(error.lowercased().contains("canonical") || error.contains("~/.claude"),
                      "got: \(error)")
        XCTAssertTrue(runner.calls(startingWith: "new-workspace").isEmpty)
    }

    /// Resuming the canonical (default) account's OWN session under another
    /// account: the canonical account is never linked to itself, only the TARGET
    /// is linked. Still launches under the target.
    func testResumeSessionFromCanonicalOwnerLinksOnlyTheTarget() async throws {
        let cwd = "/ws/feat-z"
        let id = "sess-canon"
        let canonicalDir = root.appendingPathComponent("canon-owner")
        let targetDir = root.appendingPathComponent("acc-target-2")
        try FileManager.default.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
        let mangled = ClaudeService.mangle(cwd)
        let canonProjects = canonicalDir.appendingPathComponent("projects").appendingPathComponent(mangled)
        try FileManager.default.createDirectory(at: canonProjects, withIntermediateDirectories: true)
        try "t".write(to: canonProjects.appendingPathComponent("\(id).jsonl"),
                      atomically: true, encoding: .utf8)
        let defaultAccount = AccountConfig(name: "default", configDir: canonicalDir.path)
        let target = AccountConfig(name: "work", configDir: targetDir.path)
        try ConfigStore(url: configURL).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [], accounts: [defaultAccount, target]))
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner: runner)
        state.canonicalDirOverride = canonicalDir.path
        let session = ClaudeSession(id: id, cwd: cwd, title: nil,
                                    lastActivity: Date(), accountName: "default", gitBranch: nil)

        await state.resumeSession(session, as: target)

        XCTAssertNil(state.actionError)
        // Canonical owner is NOT symlinked to itself (its file-history stays absent/real).
        XCTAssertFalse((try? FileManager.default.destinationOfSymbolicLink(
            atPath: canonicalDir.appendingPathComponent("file-history").path)) != nil,
            "the canonical account is never symlinked to itself")
        // Target is linked.
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: targetDir.appendingPathComponent("file-history").path),
            canonicalDir.appendingPathComponent("file-history").path)
        XCTAssertEqual(state.config.accounts.first { $0.name == "work" }?.sharedStore, true)
        let args = try XCTUnwrap(runner.calls(startingWith: "new-workspace").first).args
        let commandIndex = try XCTUnwrap(args.firstIndex(of: "--command"))
        XCTAssertTrue(args[commandIndex + 1].contains("--resume '\(id)'"))
    }

    /// If the SAME sessionId is live under a DIFFERENT account, resuming it under
    /// `account` would write two processes into one transcript and corrupt it.
    /// resumeSession must BLOCK (actionError naming the other account) and launch
    /// nothing — not merely warn.
    func testResumeSessionBlockedWhenSessionLiveUnderAnotherAccount() async throws {
        let cwd = "/ws/feat-x"
        let id = "sess-live"
        let canonicalDir = root.appendingPathComponent("canon-guard")
        let ownerDir = root.appendingPathComponent("acc-owner-guard")
        let targetDir = root.appendingPathComponent("acc-target-guard")
        try FileManager.default.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
        // The owner has a LIVE process for `id` recorded under its sessions/ dir.
        let ownerSessions = ownerDir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: ownerSessions, withIntermediateDirectories: true)
        try Data(#"{"pid": 999999, "sessionId": "sess-live", "cwd": "/ws/feat-x", "status": "busy"}"#.utf8)
            .write(to: ownerSessions.appendingPathComponent("999999.json"))

        let defaultAccount = AccountConfig(name: "default", configDir: canonicalDir.path)
        let owner = AccountConfig(name: "owner", configDir: ownerDir.path)
        let target = AccountConfig(name: "work", configDir: targetDir.path)
        try ConfigStore(url: configURL).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [], accounts: [defaultAccount, owner, target]))
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner: runner)
        state.canonicalDirOverride = canonicalDir.path
        // Force the validator to treat pid 999999 as alive (no real process exists).
        state.liveProcessValidatorOverride = { _ in true }
        let session = ClaudeSession(id: id, cwd: cwd, title: nil,
                                    lastActivity: Date(), accountName: "owner", gitBranch: nil)

        await state.resumeSession(session, as: target)

        let error = try XCTUnwrap(state.actionError)
        XCTAssertTrue(error.contains("owner") && error.lowercased().contains("live"),
                      "got: \(error)")
        XCTAssertTrue(runner.calls(startingWith: "new-workspace").isEmpty,
                      "a live session under another account blocks the launch")
    }

    // MARK: - createWorkspace / rollback (real git fixture)

    private func saveProjectFixture() throws -> (project: ProjectConfig, repo: RepoInfo, workspacesRoot: URL) {
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let repoURL = try FixtureLite.makeRepo(in: projectDir, name: "alpha")
        let project = ProjectConfig(name: "project", path: projectDir.path,
                                    workspacesRoot: workspacesRoot.path)
        try ConfigStore(url: configURL).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [project],
            accounts: [AccountConfig(name: "test",
                                     configDir: root.appendingPathComponent("claude-home").path)]))
        return (project, RepoInfo(path: repoURL.path, dirName: "alpha"), workspacesRoot)
    }

    func testCreateWorkspaceThenScanThenRollback() async throws {
        let fixture = try saveProjectFixture()
        let state = makeState(runner: ScriptedRunner(responses: [
            "ping": .ok("PONG"),
            "rpc": .ok(#"{"workspaces": []}"#),
        ]))

        let maybeReport = await state.createWorkspace(
            name: "feat-y", branch: "feat/y", repos: [fixture.repo], forkFrom: nil)
        let report = try XCTUnwrap(maybeReport)

        XCTAssertNil(report.failure)
        XCTAssertNil(state.actionError)
        XCTAssertEqual(report.artifacts.count, 1)
        let worktreePath = fixture.workspacesRoot.appendingPathComponent("feat-y/alpha").path
        XCTAssertEqual(report.artifacts.first?.worktreePath, worktreePath)
        XCTAssertEqual(report.artifacts.first?.branch, "feat/y")
        XCTAssertEqual(report.artifacts.first?.branchWasCreated, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath))

        // a fresh scan now sees the created workspace
        await state.refresh()
        XCTAssertEqual(state.selectedSnapshot?.workspaces.map { $0.name }, ["feat-y"])

        // rollback removes ONLY this run's artifacts
        let log = await state.rollback(report.artifacts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath))
        XCTAssertTrue(log.contains { $0.contains("removed worktree") }, "got: \(log)")

        await state.refresh()
        XCTAssertEqual(state.selectedSnapshot?.workspaces.count, 0)
    }

    func testCreateWorkspaceForwardsStartPointOverrides() async throws {
        let fixture = try saveProjectFixture()
        // A "dev" branch one commit ahead of main: the override must make the
        // new worktree start from dev's head, not main's.
        try FixtureLite.sh("git switch -qc dev", cwd: URL(fileURLWithPath: fixture.repo.path))
        try FixtureLite.commit(repo: URL(fileURLWithPath: fixture.repo.path),
                               file: "dev.txt", content: "dev\n", message: "dev work")
        let devHead = try FixtureLite.sh("git rev-parse dev",
                                         cwd: URL(fileURLWithPath: fixture.repo.path))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try FixtureLite.sh("git switch -q main", cwd: URL(fileURLWithPath: fixture.repo.path))
        let state = makeState(runner: ScriptedRunner(responses: [:]))

        let maybeReport = await state.createWorkspace(
            name: "feat-z", branch: "feat/z", repos: [fixture.repo], forkFrom: nil,
            startPointOverrides: ["alpha": "dev"])
        let report = try XCTUnwrap(maybeReport)

        XCTAssertNil(report.failure)
        let worktreePath = fixture.workspacesRoot.appendingPathComponent("feat-z/alpha").path
        let head = try FixtureLite.sh("git rev-parse HEAD",
                                      cwd: URL(fileURLWithPath: worktreePath))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(head, devHead)
    }

    func testCreateWorkspaceWithInvalidNameSetsActionError() async throws {
        let fixture = try saveProjectFixture()
        let state = makeState(runner: ScriptedRunner(responses: [:]))

        let maybeReport = await state.createWorkspace(
            name: "bad name!", branch: "feat/bad", repos: [fixture.repo], forkFrom: nil)
        let report = try XCTUnwrap(maybeReport)

        XCTAssertNotNil(report.failure)
        XCTAssertEqual(state.actionError, report.failure)
        XCTAssertTrue(report.artifacts.isEmpty)
    }

    func testCreateWorkspaceWithoutSelectedProjectReturnsNil() async {
        let state = makeState(runner: ScriptedRunner(responses: [:]))   // default config: no projects
        let report = await state.createWorkspace(name: "x", branch: "b", repos: [], forkFrom: nil)
        XCTAssertNil(report)
        XCTAssertNil(state.actionError)
    }

    // MARK: - openCmuxShell

    func testOpenCmuxShellCreatesFocusedShellOnlyWorkspace() async throws {
        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner: runner)

        await state.openCmuxShell(cwd: "/ws/feat-x", title: "feat-x")

        XCTAssertNil(state.actionError)
        let args = try XCTUnwrap(runner.calls(startingWith: "new-workspace").first).args
        // No --command pair: cmux starts its default shell in cwd.
        XCTAssertEqual(args, ["new-workspace", "--name", "feat-x", "--cwd", "/ws/feat-x",
                              "--focus", "true"])
        // focus=true activates the app through the SAME stub runner — never for real.
        XCTAssertEqual(runner.calls.filter { $0.executable == "/usr/bin/open" }.count, 1)
    }

    func testOpenCmuxShellFailureLandsInActionError() async {
        let runner = ScriptedRunner(responses: [
            "ping": .ok("PONG"),
            "new-workspace": .fail("no window"),
        ])
        let state = makeState(runner: runner)

        await state.openCmuxShell(cwd: "/ws/feat-x", title: "feat-x")

        XCTAssertNotNil(state.actionError)
    }

    // MARK: - loadGraph

    func testLoadGraphReadsRealRepo() async throws {
        let parent = root.appendingPathComponent("graph", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let repo = try FixtureLite.makeRepo(in: parent, name: "g")
        try FixtureLite.commit(repo: repo, file: "a.txt", content: "a\n", message: "second")
        let state = makeState(runner: ScriptedRunner(responses: [:]))

        await state.loadGraph(repoPath: repo.path)

        XCTAssertEqual(state.graphRepoPath, repo.path)
        XCTAssertEqual(state.graphNodes.map { $0.subject }, ["second", "base"])
        XCTAssertEqual(state.graphNodes.map { $0.lane }, [0, 0])
        XCTAssertNil(state.actionError)
    }

    func testLoadGraphFailureSetsActionErrorAndClearsNodes() async {
        let state = makeState(runner: ScriptedRunner(responses: [:]))
        await state.loadGraph(repoPath: root.appendingPathComponent("not-a-repo").path)
        XCTAssertTrue(state.graphNodes.isEmpty)
        XCTAssertNotNil(state.actionError)
    }

    // MARK: - linkAccount

    func testLinkAccountSymlinksWholesaleDirsAndMarksShared() async throws {
        let canonicalDir = root.appendingPathComponent("canon-link")
        let workDir = root.appendingPathComponent("acc-work-link")
        try FileManager.default.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
        let defaultAccount = AccountConfig(name: "default", configDir: canonicalDir.path)
        let work = AccountConfig(name: "work", configDir: workDir.path)
        try ConfigStore(url: configURL).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [], accounts: [defaultAccount, work]))
        let state = makeState(runner: ScriptedRunner(responses: [:]))
        state.canonicalDirOverride = canonicalDir.path

        state.linkAccount(work)

        XCTAssertNil(state.actionError)
        for name in SharedSessionStore.wholesaleDirs {
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
                atPath: workDir.appendingPathComponent(name).path),
                canonicalDir.appendingPathComponent(name).path)
        }
        XCTAssertEqual(state.config.accounts.first { $0.name == "work" }?.sharedStore, true)
    }

    func testLinkAccountWithoutCanonicalSetsActionError() async throws {
        let work = AccountConfig(name: "work", configDir: root.appendingPathComponent("w3").path)
        try ConfigStore(url: configURL).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [], accounts: [work]))
        let state = makeState(runner: ScriptedRunner(responses: [:]))
        state.canonicalDirOverride = root.appendingPathComponent("nope").path

        state.linkAccount(work)

        let error = try XCTUnwrap(state.actionError)
        XCTAssertTrue(error.lowercased().contains("canonical") || error.contains("~/.claude"))
        XCTAssertEqual(state.config.accounts.first { $0.name == "work" }?.sharedStore, false)
    }
}
