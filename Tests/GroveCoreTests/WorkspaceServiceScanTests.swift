import XCTest
@testable import GroveCore

final class WorkspaceServiceScanTests: XCTestCase {

    // MARK: - workspacesRoot template resolution

    func testWorkspacesRootUsesTemplateSubstitution() {
        let project = ProjectConfig(name: "myproj", path: "/tmp/myproj")
        var config = GroveConfig.defaultConfig
        config.workspacesRootTemplate = "~/Workspaces/{project}"
        config.projects = [project]
        config.accounts = []
        let service = WorkspaceService(git: GitService(), claude: ClaudeService(),
                                       cmux: CmuxService(), config: config)
        XCTAssertEqual(service.workspacesRoot(for: project), expandTilde("~/Workspaces/myproj"))
    }

    func testWorkspacesRootOverrideWins() {
        var project = ProjectConfig(name: "myproj", path: "/tmp/myproj")
        project.workspacesRoot = "~/CustomRoot/special"
        var config = GroveConfig.defaultConfig
        config.workspacesRootTemplate = "~/Workspaces/{project}"
        config.projects = [project]
        config.accounts = []
        let service = WorkspaceService(git: GitService(), claude: ClaudeService(),
                                       cmux: CmuxService(), config: config)
        XCTAssertEqual(service.workspacesRoot(for: project), expandTilde("~/CustomRoot/special"))
    }

    // MARK: - depth basis for parent ranking: rev-list --count base..mergeBase

    func testRevListCountMeasuresDepthFromBase() async throws {
        let base = try Fixture.tempDir("revlist").resolvingSymlinksInPath()
        let repo = try Fixture.makeRepo(in: base, name: "r")
        let wt = base.appendingPathComponent("wt")
        try Fixture.addWorktree(repo: repo, branch: "feat/a", from: "main", at: wt)
        try Fixture.commit(repo: wt, file: "a.txt", content: "a", message: "a1")
        try Fixture.commit(repo: wt, file: "b.txt", content: "b", message: "a2")

        let git = GitService()
        let mbOpt = await git.mergeBase(repoPath: repo.path, "feat/a", "feat/a")
        let mb = try XCTUnwrap(mbOpt)                      // tip of feat/a
        let depthA = await git.revListCount(repoPath: repo.path, from: "main", to: mb)
        XCTAssertEqual(depthA, 2)
        let depthBase = await git.revListCount(repoPath: repo.path, from: "main", to: "main")
        XCTAssertEqual(depthBase, 0)
    }

    // MARK: - full scan fixture

    func testScanClassifiesGroupsAndStacks() async throws {
        // One resolved temp base; every fixture path derives from it so that
        // string comparisons line up with scan's canonical form.
        let base = try Fixture.tempDir("scan").resolvingSymlinksInPath()
        let fm = FileManager.default
        let projectDir = base.appendingPathComponent("project")
        let wsRoot = base.appendingPathComponent("workspaces")
        let claudeDir = base.appendingPathComponent("claude-account")
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: wsRoot, withIntermediateDirectories: true)

        // -- repos r1, r2 inside the project
        let r1 = try Fixture.makeRepo(in: projectDir, name: "r1")
        let r2 = try Fixture.makeRepo(in: projectDir, name: "r2")

        // -- workspace alpha: worktrees of r1 + r2 on feat/alpha, forked from main
        let alphaUmbrella = wsRoot.appendingPathComponent("alpha")
        try Fixture.addWorktree(repo: r1, branch: "feat/alpha", from: "main",
                                at: alphaUmbrella.appendingPathComponent("r1"))
        try Fixture.addWorktree(repo: r2, branch: "feat/alpha", from: "main",
                                at: alphaUmbrella.appendingPathComponent("r2"))

        // one commit on alpha in r1 BEFORE forking beta -> fork-point depth becomes 1
        try Fixture.commit(repo: alphaUmbrella.appendingPathComponent("r1"),
                           file: "alpha.txt", content: "alpha work", message: "alpha: work")

        // -- workspace beta: forked FROM feat/alpha, r1 only, two own commits
        let betaUmbrella = wsRoot.appendingPathComponent("beta")
        try Fixture.addWorktree(repo: r1, branch: "feat/beta", from: "feat/alpha",
                                at: betaUmbrella.appendingPathComponent("r1"))
        try Fixture.commit(repo: betaUmbrella.appendingPathComponent("r1"),
                           file: "beta1.txt", content: "b1", message: "beta: one")
        try Fixture.commit(repo: betaUmbrella.appendingPathComponent("r1"),
                           file: "beta2.txt", content: "b2", message: "beta: two")

        // -- a worktree parked DEEPER inside alpha (what agent workflows leave):
        //    alpha/wt/r1-extra — part of alpha's area, not one of its repo checkouts.
        try Fixture.addWorktree(repo: r1, branch: "feat/alpha-extra", from: "feat/alpha",
                                at: alphaUmbrella.appendingPathComponent("wt").appendingPathComponent("r1-extra"))

        // -- loose worktree gamma under r1/.worktrees/gamma (outside workspaces root)
        try Fixture.addWorktree(repo: r1, branch: "gamma", from: "main",
                                at: r1.appendingPathComponent(".worktrees").appendingPathComponent("gamma"))

        // -- claude session fixture: one jsonl whose cwd is the alpha umbrella
        let umbrella = alphaUmbrella.path
        let sessionDir = claudeDir
            .appendingPathComponent("projects")
            .appendingPathComponent(ClaudeService.mangle(umbrella))
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let jsonl = """
        {"type":"user","sessionId":"x","cwd":"\(umbrella)","gitBranch":"feat/alpha","message":{"role":"user","content":"Start alpha work"}}
        {"type":"ai-title","aiTitle":"Alpha feature"}
        """
        try jsonl.write(to: sessionDir.appendingPathComponent("x.jsonl"),
                        atomically: true, encoding: .utf8)

        // -- cmux: MockRunner-backed service returning one workspace inside the alpha umbrella
        let cmuxJSON = """
        [{"id":"cmux-1","title":"alpha","current_directory":"\(umbrella)/r1"}]
        """
        let mock = MockRunner(results: [ProcessResult(exitCode: 0, stdout: cmuxJSON, stderr: "")])
        let cmuxService = CmuxService(runner: mock, cmuxPath: "/opt/fake/cmux")

        // -- config + service (REAL GitService, REAL ClaudeService)
        var project = ProjectConfig(name: "scanproj", path: projectDir.path)
        project.workspacesRoot = wsRoot.path
        var config = GroveConfig.defaultConfig
        config.projects = [project]
        config.accounts = [AccountConfig(name: "default", configDir: claudeDir.path)]
        let service = WorkspaceService(git: GitService(), claude: ClaudeService(),
                                       cmux: cmuxService, config: config)

        let snapshot = await service.scan(project: project)

        // -- repos discovered, no errors anywhere
        XCTAssertEqual(Set(snapshot.repos.map(\.dirName)), ["r1", "r2"])
        XCTAssertEqual(snapshot.errors, [])

        // -- workspaces grouped by umbrella subdir name
        XCTAssertEqual(snapshot.workspaces.map(\.name).sorted(), ["alpha", "beta"])
        guard let alpha = snapshot.workspaces.first(where: { $0.name == "alpha" }),
              let beta = snapshot.workspaces.first(where: { $0.name == "beta" }) else {
            XCTFail("missing alpha/beta workspaces")
            return
        }
        XCTAssertEqual(alpha.umbrellaPath, umbrella)
        XCTAssertEqual(Set(alpha.repos.map(\.repo.dirName)), ["r1", "r2"])
        XCTAssertEqual(beta.repos.map(\.repo.dirName), ["r1"])
        // -- the parked worktree is listed under alpha's fold, not among its repos
        XCTAssertEqual(alpha.nestedWorktrees.map(\.entry.branch), ["feat/alpha-extra"])
        XCTAssertTrue(alpha.nestedWorktrees[0].entry.path.hasSuffix("/alpha/wt/r1-extra"))
        XCTAssertEqual(beta.nestedWorktrees, [])

        // -- stacking: alpha is a root, beta is stacked on alpha
        XCTAssertNil(alpha.parentName)
        XCTAssertEqual(beta.parentName, "alpha")

        // -- beta meta is relative to feat/alpha, NOT main
        let betaR1 = try XCTUnwrap(beta.repos.first)
        let betaMeta = try XCTUnwrap(betaR1.meta)
        XCTAssertEqual(betaMeta.baseBranch, "feat/alpha")
        XCTAssertEqual(betaMeta.ahead, 2)        // beta-only commits; would be 3 against main
        XCTAssertEqual(betaMeta.behind, 0)
        let alphaR1 = try XCTUnwrap(alpha.repos.first(where: { $0.repo.dirName == "r1" }))
        XCTAssertEqual(betaMeta.forkPoint, alphaR1.entry.head)

        // -- alpha meta is relative to main
        let alphaMeta = try XCTUnwrap(alphaR1.meta)
        XCTAssertEqual(alphaMeta.baseBranch, "main")
        XCTAssertEqual(alphaMeta.ahead, 1)

        // -- loose worktree gamma
        XCTAssertEqual(snapshot.loose.count, 1)
        let gamma = try XCTUnwrap(snapshot.loose.first)
        XCTAssertEqual(gamma.repo.dirName, "r1")
        XCTAssertEqual(gamma.entry.branch, "gamma")
        XCTAssertTrue(gamma.entry.path.hasSuffix("/.worktrees/gamma"))
        XCTAssertEqual(gamma.sessions, [])
        XCTAssertEqual(gamma.cmuxWorkspaces, [])

        // -- sessions attached to alpha only
        XCTAssertEqual(alpha.sessions.count, 1)
        XCTAssertEqual(alpha.sessions.first?.cwd, umbrella)
        XCTAssertEqual(alpha.sessions.first?.id, "x")
        XCTAssertEqual(alpha.sessions.first?.accountName, "default")
        XCTAssertEqual(alpha.liveProcesses, [])
        XCTAssertEqual(beta.sessions, [])

        // -- cmux matched to alpha only (current_directory inside the umbrella)
        XCTAssertEqual(alpha.cmuxWorkspaces,
                       [CmuxWorkspace(id: "cmux-1", title: "alpha", currentDirectory: umbrella + "/r1")])
        XCTAssertEqual(beta.cmuxWorkspaces, [])
    }

    // MARK: - degrade contract: scan never throws, failures accumulate in snapshot.errors

    func testScanRecordsCmuxFailureAsErrorAndStillReturnsWorkspaces() async throws {
        let base = try Fixture.tempDir("scan-cmux-fail").resolvingSymlinksInPath()
        let projectDir = base.appendingPathComponent("project")
        let wsRoot = base.appendingPathComponent("workspaces")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)

        let r1 = try Fixture.makeRepo(in: projectDir, name: "r1")
        try Fixture.addWorktree(repo: r1, branch: "feat/alpha", from: "main",
                                at: wsRoot.appendingPathComponent("alpha").appendingPathComponent("r1"))

        // cmux exits non-zero -> runOK throws GroveError.processFailed inside listWorkspaces.
        let mock = MockRunner(results: [ProcessResult(exitCode: 1, stdout: "", stderr: "cmux exploded")])
        let cmuxService = CmuxService(runner: mock, cmuxPath: "/opt/fake/cmux")

        var project = ProjectConfig(name: "scanproj", path: projectDir.path)
        project.workspacesRoot = wsRoot.path
        var config = GroveConfig.defaultConfig
        config.projects = [project]
        config.accounts = []
        let service = WorkspaceService(git: GitService(), claude: ClaudeService(),
                                       cmux: cmuxService, config: config)

        let snapshot = await service.scan(project: project)

        // The failure is recorded, never thrown ...
        XCTAssertEqual(snapshot.errors.count, 1)
        XCTAssertTrue(snapshot.errors.first?.hasPrefix("cmux:") ?? false,
                      "cmux failure must be recorded as a 'cmux:' snapshot error, got: \(snapshot.errors)")
        // ... and the rest of the snapshot is still fully assembled.
        XCTAssertEqual(snapshot.repos.map(\.dirName), ["r1"])
        XCTAssertEqual(snapshot.workspaces.map(\.name), ["alpha"])
        XCTAssertEqual(snapshot.workspaces.first?.cmuxWorkspaces, [])
    }

    func testScanRecordsWorktreeListFailureAsError() async throws {
        let base = try Fixture.tempDir("scan-wt-fail").resolvingSymlinksInPath()
        let projectDir = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        _ = try Fixture.makeRepo(in: projectDir, name: "r1")

        // Repo discovery is filesystem-based, so r1 is still found; the FIRST
        // runner call is `git worktree list --porcelain`, which fails here ->
        // worktrees(repo:) throws -> scan degrades to errors.append.
        let gitMock = MockRunner(results: [ProcessResult(exitCode: 1, stdout: "", stderr: "boom")])
        let cmuxMock = MockRunner(results: [ProcessResult(exitCode: 0, stdout: "[]", stderr: "")])

        var project = ProjectConfig(name: "scanproj", path: projectDir.path)
        project.workspacesRoot = base.appendingPathComponent("workspaces").path
        var config = GroveConfig.defaultConfig
        config.projects = [project]
        config.accounts = []
        let service = WorkspaceService(git: GitService(runner: gitMock), claude: ClaudeService(),
                                       cmux: CmuxService(runner: cmuxMock, cmuxPath: "/opt/fake/cmux"),
                                       config: config)

        let snapshot = await service.scan(project: project)

        XCTAssertEqual(snapshot.repos.map(\.dirName), ["r1"])
        XCTAssertEqual(snapshot.errors.count, 1)
        XCTAssertTrue(snapshot.errors.first?.hasPrefix("worktrees r1:") ?? false,
                      "worktree listing failure must be recorded as a 'worktrees r1:' snapshot error, got: \(snapshot.errors)")
        XCTAssertEqual(snapshot.workspaces.count, 0)
        XCTAssertEqual(snapshot.loose.count, 0)
    }

    // MARK: - live processes: listed once per scan, filtered per path

    func testScanListsLiveProcessesOncePerScanAndAttachesByCwd() async throws {
        let base = try Fixture.tempDir("scan-live").resolvingSymlinksInPath()
        let fm = FileManager.default
        let projectDir = base.appendingPathComponent("project")
        let wsRoot = base.appendingPathComponent("workspaces")
        let claudeDir = base.appendingPathComponent("claude-account")
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: wsRoot, withIntermediateDirectories: true)

        // One workspace AND one loose worktree: two distinct attach sites, so a
        // per-site re-listing regression would double the validator call count.
        let r1 = try Fixture.makeRepo(in: projectDir, name: "r1")
        let alphaR1 = wsRoot.appendingPathComponent("alpha").appendingPathComponent("r1")
        try Fixture.addWorktree(repo: r1, branch: "feat/alpha", from: "main", at: alphaR1)
        try Fixture.addWorktree(repo: r1, branch: "gamma", from: "main",
                                at: r1.appendingPathComponent(".worktrees").appendingPathComponent("gamma"))

        // One live-process record whose cwd lies inside the alpha umbrella.
        let sessionsDir = claudeDir.appendingPathComponent("sessions")
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try #"{"pid":4242,"sessionId":"live-1","cwd":"\#(alphaR1.path)","status":"busy"}"#
            .write(to: sessionsDir.appendingPathComponent("4242.json"), atomically: true, encoding: .utf8)

        let claude = ClaudeService()
        var validatorCalls = 0
        claude.processValidator = { _ in
            validatorCalls += 1
            return true
        }

        let cmuxMock = MockRunner(results: [ProcessResult(exitCode: 0, stdout: "[]", stderr: "")])
        var project = ProjectConfig(name: "scanproj", path: projectDir.path)
        project.workspacesRoot = wsRoot.path
        var config = GroveConfig.defaultConfig
        config.projects = [project]
        config.accounts = [AccountConfig(name: "default", configDir: claudeDir.path)]
        let service = WorkspaceService(git: GitService(), claude: claude,
                                       cmux: CmuxService(runner: cmuxMock, cmuxPath: "/opt/fake/cmux"),
                                       config: config)

        let snapshot = await service.scan(project: project)

        XCTAssertEqual(snapshot.errors, [])
        XCTAssertEqual(validatorCalls, 1,
                       "liveProcesses is path-independent and must be listed exactly once per scan, " +
                       "not re-listed per workspace/loose worktree")

        // The single snapshot is filtered per path: attached to alpha, not to gamma.
        let alpha = try XCTUnwrap(snapshot.workspaces.first(where: { $0.name == "alpha" }))
        XCTAssertEqual(alpha.liveProcesses,
                       [LiveProcess(pid: 4242, sessionId: "live-1", cwd: alphaR1.path,
                                    status: "busy", accountName: "default")])
        let gamma = try XCTUnwrap(snapshot.loose.first)
        XCTAssertEqual(gamma.liveProcesses, [])
    }
}
