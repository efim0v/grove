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

    private func makeState(runner: ScriptedRunner) -> AppState {
        let state = AppState(configStore: ConfigStore(url: configURL))
        state.cmuxOverride = stubbedCmux(runner)
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

    /// Same-account resume copies nothing and just launches --resume in the
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

    /// Cross-account resume copies the source jsonl into the target account's
    /// identical projects/<mangle(cwd)>/ path, then launches --resume under the
    /// target account's CLAUDE_CONFIG_DIR.
    func testResumeSessionCrossAccountCopiesJsonlThenLaunchesUnderTarget() async throws {
        let cwd = "/ws/feat-x"
        let id = "sess-cross"
        // Two real config dirs; source owns the transcript.
        let srcDir = root.appendingPathComponent("acc-src")
        let dstDir = root.appendingPathComponent("acc-dst")
        let source = AccountConfig(name: "owner", configDir: srcDir.path)
        let target = AccountConfig(name: "work", configDir: dstDir.path)
        try ConfigStore(url: configURL).save(GroveConfig(
            version: 1, workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [], accounts: [source, target]))

        let mangled = ClaudeService.mangle(cwd)
        let srcProjects = srcDir.appendingPathComponent("projects").appendingPathComponent(mangled)
        try FileManager.default.createDirectory(at: srcProjects, withIntermediateDirectories: true)
        try "transcript".write(to: srcProjects.appendingPathComponent("\(id).jsonl"),
                               atomically: true, encoding: .utf8)

        let runner = ScriptedRunner(responses: ["ping": .ok("PONG")])
        let state = makeState(runner: runner)
        let session = ClaudeSession(id: id, cwd: cwd, title: nil,
                                    lastActivity: Date(), accountName: "owner", gitBranch: nil)

        await state.resumeSession(session, as: target)

        XCTAssertNil(state.actionError)
        // Copied into target's projects dir.
        let dstJsonl = dstDir.appendingPathComponent("projects")
            .appendingPathComponent(mangled).appendingPathComponent("\(id).jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstJsonl.path))
        // Launched under the TARGET account's config dir.
        let args = try XCTUnwrap(runner.calls(startingWith: "new-workspace").first).args
        let commandIndex = try XCTUnwrap(args.firstIndex(of: "--command"))
        XCTAssertTrue(args[commandIndex + 1].contains("CLAUDE_CONFIG_DIR=\(shellQuote(dstDir.path))"))
        XCTAssertTrue(args[commandIndex + 1].contains("--resume '\(id)'"))
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
}
