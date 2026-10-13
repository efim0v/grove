import XCTest
@testable import GroveCore

final class WorkspaceCreateTests: XCTestCase {
    var baseDir: URL!
    var projectDir: URL!
    var workspacesRoot: URL!
    var r1: URL!
    var r2: URL!

    override func setUpWithError() throws {
        baseDir = try Fixture.tempDir("create")
        projectDir = baseDir.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        r1 = try Fixture.makeRepo(in: projectDir, name: "repo-one")
        r2 = try Fixture.makeRepo(in: projectDir, name: "repo-two")
        workspacesRoot = baseDir.appendingPathComponent("workspaces")
    }

    // MARK: - helpers

    private func makeProject(hooks: [String: String] = [:]) -> ProjectConfig {
        ProjectConfig(
            name: "proj",
            path: projectDir.path,
            workspacesRoot: workspacesRoot.path,
            postCreateHooks: hooks
        )
    }

    private func makeService() -> WorkspaceService {
        WorkspaceService(git: GitService(), claude: ClaudeService(), cmux: CmuxService(),
                         config: GroveConfig.defaultConfig)
    }

    private var repo1: RepoInfo { RepoInfo(path: r1.path, dirName: "repo-one") }
    private var repo2: RepoInfo { RepoInfo(path: r2.path, dirName: "repo-two") }

    private func revParse(_ dir: URL, _ ref: String) throws -> String {
        try Fixture.sh("git -C \(dir.path) rev-parse \(ref)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func branchExists(_ repo: URL, _ branch: String) throws -> Bool {
        try !Fixture.sh("git -C \(repo.path) branch --list \(branch)")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - happy path

    func testCreateWorkspaceHappyPath() async throws {
        let report = await makeService().createWorkspace(
            project: makeProject(), name: "delta", branch: "feat/delta",
            repos: [repo1, repo2], forkFrom: nil)

        XCTAssertNil(report.failure)
        XCTAssertEqual(report.artifacts.count, 2)
        XCTAssertTrue(report.artifacts.allSatisfy { $0.branchWasCreated })

        let wt1 = workspacesRoot.appendingPathComponent("delta/repo-one")
        let wt2 = workspacesRoot.appendingPathComponent("delta/repo-two")
        XCTAssertTrue(isDirectory(wt1.path))
        XCTAssertTrue(isDirectory(wt2.path))

        XCTAssertEqual(try revParse(wt1, "--abbrev-ref HEAD"), "feat/delta")
        XCTAssertEqual(try revParse(wt2, "--abbrev-ref HEAD"), "feat/delta")
        XCTAssertTrue(try branchExists(r1, "feat/delta"))
        XCTAssertTrue(try branchExists(r2, "feat/delta"))
    }

    // MARK: - fork from parent workspace (stacking)

    func testForkFromParentUsesParentTipWhereCovered() async throws {
        // feat/alpha exists in repo-one only, one commit ahead of main.
        let alphaPath = baseDir.appendingPathComponent("alpha-wt")
        try Fixture.addWorktree(repo: r1, branch: "feat/alpha", from: "main", at: alphaPath)
        try Fixture.commit(repo: alphaPath, file: "alpha.txt", content: "a", message: "alpha work")
        let alphaTip = try revParse(alphaPath, "HEAD")
        let mainTip1 = try revParse(r1, "main")
        let mainTip2 = try revParse(r2, "main")
        XCTAssertNotEqual(alphaTip, mainTip1)

        // Synthesize the parent FeatureWorkspace covering repo-one only.
        let alphaEntry = WorktreeEntry(path: alphaPath.path, branch: "feat/alpha",
                                       head: alphaTip, isMain: false)
        let alphaState = WorkspaceRepoState(repo: repo1, entry: alphaEntry, meta: nil, scanError: nil)
        let alpha = FeatureWorkspace(
            name: "alpha", umbrellaPath: alphaPath.path, repos: [alphaState],
            parentName: nil, sessions: [], liveProcesses: [], cmuxWorkspaces: [])

        let report = await makeService().createWorkspace(
            project: makeProject(), name: "delta-from-alpha", branch: "feat/delta-from-alpha",
            repos: [repo1, repo2], forkFrom: alpha)

        XCTAssertNil(report.failure)
        // repo-one: starts at the parent branch tip.
        XCTAssertEqual(try revParse(r1, "feat/delta-from-alpha"), alphaTip)
        // repo-two: parent does not cover it -> starts at base.
        XCTAssertEqual(try revParse(r2, "feat/delta-from-alpha"), mainTip2)
    }

    // MARK: - startPointOverrides

    func testStartPointOverrideBeatsBase() async throws {
        // Create a feature branch "custom-start" in repo-one, one commit ahead of main.
        let customWt = baseDir.appendingPathComponent("custom-wt")
        try Fixture.addWorktree(repo: r1, branch: "custom-start", from: "main", at: customWt)
        try Fixture.commit(repo: customWt, file: "extra.txt", content: "x", message: "extra commit")
        let customTip = try revParse(customWt, "HEAD")
        let mainTip1 = try revParse(r1, "main")
        XCTAssertNotEqual(customTip, mainTip1, "prerequisite: custom-start must diverge from main")

        let report = await makeService().createWorkspace(
            project: makeProject(), name: "override-test", branch: "feat/override-test",
            repos: [repo1, repo2], forkFrom: nil,
            startPointOverrides: ["repo-one": "custom-start"])

        XCTAssertNil(report.failure)
        // repo-one: forked from custom-start tip.
        XCTAssertEqual(try revParse(r1, "feat/override-test"), customTip)
        // repo-two: no override, uses base (main).
        let mainTip2 = try revParse(r2, "main")
        XCTAssertEqual(try revParse(r2, "feat/override-test"), mainTip2)
        // Log must mention the actual start point used.
        XCTAssertTrue(report.logLines.contains { $0.contains("custom-start") },
                      "log lines must mention the start point: \(report.logLines)")
    }

    func testStartPointOverrideBeatsParent() async throws {
        // Set up parent workspace with a commit in repo-one.
        let alphaPath = baseDir.appendingPathComponent("alpha-wt2")
        try Fixture.addWorktree(repo: r1, branch: "feat/alpha2", from: "main", at: alphaPath)
        try Fixture.commit(repo: alphaPath, file: "alpha.txt", content: "a", message: "alpha work")
        let alphaTip = try revParse(alphaPath, "HEAD")

        // Also create a "custom-start" branch in repo-one with a different tip.
        let customWt = baseDir.appendingPathComponent("custom-wt2")
        try Fixture.addWorktree(repo: r1, branch: "custom-start2", from: "main", at: customWt)
        try Fixture.commit(repo: customWt, file: "custom.txt", content: "c", message: "custom commit")
        let customTip = try revParse(customWt, "HEAD")
        XCTAssertNotEqual(alphaTip, customTip, "prerequisite: tips must differ")

        let alphaEntry = WorktreeEntry(path: alphaPath.path, branch: "feat/alpha2",
                                       head: alphaTip, isMain: false)
        let alphaState = WorkspaceRepoState(repo: repo1, entry: alphaEntry, meta: nil, scanError: nil)
        let alpha = FeatureWorkspace(
            name: "alpha2", umbrellaPath: alphaPath.path, repos: [alphaState],
            parentName: nil, sessions: [], liveProcesses: [], cmuxWorkspaces: [])

        // Override for repo-one beats the parent branch.
        let report = await makeService().createWorkspace(
            project: makeProject(), name: "override-beats-parent", branch: "feat/override-beats-parent",
            repos: [repo1, repo2], forkFrom: alpha,
            startPointOverrides: ["repo-one": "custom-start2"])

        XCTAssertNil(report.failure)
        // repo-one: override wins over parent branch.
        XCTAssertEqual(try revParse(r1, "feat/override-beats-parent"), customTip)
    }

    func testDefaultEmptyOverridesKeepsExistingBehavior() async throws {
        // Ensure calling without startPointOverrides still works (backward compat).
        let report = await makeService().createWorkspace(
            project: makeProject(), name: "compat-check", branch: "feat/compat-check",
            repos: [repo1, repo2], forkFrom: nil)
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.artifacts.count, 2)
    }

    // MARK: - start point that is only a remote branch (issue #26)

    /// An upstream whose release-2 is one commit ahead of main, cloned into the
    /// project as `cloned`: the clone has release-2 only as origin/release-2.
    private func makeClone() throws -> (url: URL, repo: RepoInfo, releaseTip: String) {
        let upstream = try Fixture.makeRepo(in: baseDir, name: "upstream")
        try Fixture.sh("git -C \(shellQuote(upstream.path)) checkout -q -b release-2")
        try Fixture.commit(repo: upstream, file: "release.txt", content: "r", message: "release work")
        try Fixture.sh("git -C \(shellQuote(upstream.path)) checkout -q main")
        let clone = projectDir.appendingPathComponent("cloned")
        try Fixture.sh("git clone -q \(shellQuote(upstream.path)) \(shellQuote(clone.path))")
        return (clone, RepoInfo(path: clone.path, dirName: "cloned"), try revParse(upstream, "release-2"))
    }

    func testStartPointOnlyOnOriginForksTheWorkspaceBranch() async throws {
        let clone = try makeClone()
        XCTAssertFalse(try branchExists(clone.url, "release-2"), "prerequisite: release-2 is only on origin")

        let report = await makeService().createWorkspace(
            project: makeProject(), name: "rel", branch: "feat/rel",
            repos: [clone.repo], forkFrom: nil, startPointOverrides: ["cloned": "release-2"])

        XCTAssertNil(report.failure, "\(report.logLines)")
        let wt = workspacesRoot.appendingPathComponent("rel/cloned")
        XCTAssertEqual(try revParse(wt, "--abbrev-ref HEAD"), "feat/rel")
        XCTAssertEqual(try revParse(clone.url, "feat/rel"), clone.releaseTip)
        // git did not make up a local release-2 (tracking origin) and check that out.
        XCTAssertFalse(try branchExists(clone.url, "release-2"))
        XCTAssertTrue(report.logLines.contains { $0.contains("from origin/release-2") },
                      "log lines must name the start point used: \(report.logLines)")
    }

    func testBaseBranchOverrideOnlyOnOriginForksTheWorkspaceBranch() async throws {
        let clone = try makeClone()
        let project = ProjectConfig(name: "proj", path: projectDir.path,
                                    workspacesRoot: workspacesRoot.path,
                                    baseBranchOverrides: ["cloned": "release-2"])

        let report = await makeService().createWorkspace(
            project: project, name: "rel-base", branch: "feat/rel-base",
            repos: [clone.repo], forkFrom: nil)

        XCTAssertNil(report.failure, "\(report.logLines)")
        let wt = workspacesRoot.appendingPathComponent("rel-base/cloned")
        XCTAssertEqual(try revParse(wt, "--abbrev-ref HEAD"), "feat/rel-base")
        XCTAssertEqual(try revParse(clone.url, "feat/rel-base"), clone.releaseTip)
        XCTAssertFalse(try branchExists(clone.url, "release-2"))
    }

    func testLocalBranchStartPointWinsOverOrigin() async throws {
        let clone = try makeClone()
        // A local release-2 that is not origin's: it sits on main, a commit behind.
        try Fixture.sh("git -C \(shellQuote(clone.url.path)) branch --no-track release-2 origin/main")
        let localTip = try revParse(clone.url, "release-2")
        XCTAssertNotEqual(localTip, clone.releaseTip, "prerequisite: local and origin release-2 differ")

        let report = await makeService().createWorkspace(
            project: makeProject(), name: "rel-local", branch: "feat/rel-local",
            repos: [clone.repo], forkFrom: nil, startPointOverrides: ["cloned": "release-2"])

        XCTAssertNil(report.failure, "\(report.logLines)")
        let wt = workspacesRoot.appendingPathComponent("rel-local/cloned")
        XCTAssertEqual(try revParse(wt, "--abbrev-ref HEAD"), "feat/rel-local")
        XCTAssertEqual(try revParse(clone.url, "feat/rel-local"), localTip)
    }

    /// A branch only a remote other than origin has is handed to git as typed. git
    /// 2.54 then makes up a local branch of that name and checks it out instead of the
    /// workspace branch, exit 0; a git that rejects the name fails the add. Either way
    /// creation stops with nothing of that repo left: no worktree, no made-up branch.
    func testStartPointOnlyOnAnotherRemoteLeavesNothingBehind() async throws {
        let clone = try makeClone()
        let fork = baseDir.appendingPathComponent("fork")
        try Fixture.sh("git clone -q \(shellQuote(clone.url.path)) \(shellQuote(fork.path))")
        try Fixture.sh("git -C \(shellQuote(fork.path)) branch fork-only")
        try Fixture.sh("git -C \(shellQuote(clone.url.path)) remote add fork \(shellQuote(fork.path))")
        try Fixture.sh("git -C \(shellQuote(clone.url.path)) fetch -q fork")

        let report = await makeService().createWorkspace(
            project: makeProject(), name: "forked", branch: "feat/forked",
            repos: [repo1, clone.repo], forkFrom: nil, startPointOverrides: ["cloned": "fork-only"])

        XCTAssertNotNil(report.failure)
        // repo-one went first: its worktree stays, an artifact for the user's rollback.
        XCTAssertEqual(report.artifacts.map(\.repoPath), [r1.path])
        XCTAssertTrue(isDirectory(workspacesRoot.appendingPathComponent("forked/repo-one").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspacesRoot.appendingPathComponent("forked/cloned").path))
        let worktrees = try await GitService().worktrees(repo: clone.repo)
        XCTAssertEqual(worktrees.count, 1, "only the clone's main worktree is left")
        XCTAssertFalse(try branchExists(clone.url, "fork-only"))
        XCTAssertFalse(try branchExists(clone.url, "feat/forked"))
    }

    /// A service whose git reports the worktree at `worktreePath` on `somewhere-else`,
    /// whatever git really checked out there; every other command runs for real.
    /// Faking HEAD keeps these tests independent of how a git version errs.
    private func serviceWithHeadElsewhere(at worktreePath: String) -> WorkspaceService {
        struct HeadElsewhere: CommandRunning {
            let worktreePath: String
            func run(_ executable: String, _ args: [String], cwd: String?, env: [String: String]?,
                     timeout: TimeInterval) async throws -> ProcessResult {
                if args == ["-C", worktreePath, "symbolic-ref", "HEAD"] {
                    return ProcessResult(exitCode: 0, stdout: "refs/heads/somewhere-else\n", stderr: "")
                }
                return try await ProcessRunner().run(executable, args, cwd: cwd, env: env, timeout: timeout)
            }
        }
        return WorkspaceService(git: GitService(runner: HeadElsewhere(worktreePath: worktreePath)),
                                claude: ClaudeService(), cmux: CmuxService(),
                                config: GroveConfig.defaultConfig)
    }

    /// Whatever made git land elsewhere, a worktree that is not on the workspace
    /// branch fails creation and is rolled back with the branch the add created.
    func testWorktreeOnAnotherBranchIsRolledBack() async throws {
        let worktreePath = workspacesRoot.appendingPathComponent("elsewhere/repo-one").path

        let report = await serviceWithHeadElsewhere(at: worktreePath).createWorkspace(
            project: makeProject(), name: "elsewhere", branch: "feat/elsewhere",
            repos: [repo1], forkFrom: nil)

        XCTAssertEqual(report.failure,
                       "worktree add failed in repo-one: git checked out somewhere-else, not feat/elsewhere")
        XCTAssertTrue(report.artifacts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath))
        XCTAssertFalse(try branchExists(r1, "feat/elsewhere"))
        let worktrees = try await GitService().worktrees(repo: repo1)
        XCTAssertEqual(worktrees.count, 1)
    }

    /// The same failure on a workspace branch that existed before the run: the
    /// rollback removes the worktree and leaves the branch where it was.
    func testWorktreeOnAnotherBranchKeepsABranchThatExisted() async throws {
        let existing = baseDir.appendingPathComponent("existing-wt")
        try Fixture.addWorktree(repo: r1, branch: "feat/existing", from: "main", at: existing)
        try Fixture.commit(repo: existing, file: "existing.txt", content: "e", message: "existing work")
        let tip = try revParse(existing, "HEAD")
        // Free the branch so the workspace can check it out.
        try Fixture.sh("git -C \(shellQuote(r1.path)) worktree remove \(shellQuote(existing.path))")
        let worktreePath = workspacesRoot.appendingPathComponent("existing/repo-one").path

        let report = await serviceWithHeadElsewhere(at: worktreePath).createWorkspace(
            project: makeProject(), name: "existing", branch: "feat/existing",
            repos: [repo1], forkFrom: nil)

        XCTAssertEqual(report.failure,
                       "worktree add failed in repo-one: git checked out somewhere-else, not feat/existing")
        XCTAssertTrue(report.artifacts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath))
        XCTAssertEqual(try revParse(r1, "feat/existing"), tip)
    }

    // MARK: - validation, BEFORE any git operation

    func testInvalidNamesFailBeforeAnyGitOperation() async throws {
        for bad in ["../evil", "a b"] {
            let report = await makeService().createWorkspace(
                project: makeProject(), name: bad, branch: "feat/bad",
                repos: [repo1, repo2], forkFrom: nil)
            XCTAssertNotNil(report.failure, "name \(bad) must be rejected")
            XCTAssertTrue(report.artifacts.isEmpty)
            XCTAssertFalse(try branchExists(r1, "feat/bad"))
            XCTAssertFalse(try branchExists(r2, "feat/bad"))
        }
        // Nothing was created — not even the workspaces root.
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspacesRoot.path))
    }

    func testExistingUmbrellaFailsBeforeGitOps() async throws {
        // An umbrella that already hosts a workspace directory.
        let occupied = workspacesRoot.appendingPathComponent("occupied/repo-one")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)

        let report = await makeService().createWorkspace(
            project: makeProject(), name: "occupied", branch: "feat/occupied",
            repos: [repo1, repo2], forkFrom: nil)

        XCTAssertNotNil(report.failure)
        XCTAssertTrue(report.artifacts.isEmpty)
        XCTAssertFalse(try branchExists(r1, "feat/occupied"))
        XCTAssertFalse(try branchExists(r2, "feat/occupied"))
    }

    // MARK: - mid-failure stop + rollback

    func testMidFailureStopsAndRollbackRemovesArtifacts() async throws {
        let umbrella = workspacesRoot.appendingPathComponent("midfail")
        try FileManager.default.createDirectory(at: umbrella, withIntermediateDirectories: true)
        // A FILE at the would-be SECOND worktree path makes repo-two's worktree add fail.
        let blocker = umbrella.appendingPathComponent("repo-two")
        try Data("in the way".utf8).write(to: blocker)

        let service = makeService()
        let report = await service.createWorkspace(
            project: makeProject(), name: "midfail", branch: "feat/midfail",
            repos: [repo1, repo2], forkFrom: nil)

        XCTAssertNotNil(report.failure)
        XCTAssertEqual(report.artifacts.count, 1)
        XCTAssertEqual(report.artifacts[0].repoPath, r1.path)
        XCTAssertTrue(report.artifacts[0].branchWasCreated)
        XCTAssertTrue(isDirectory(umbrella.appendingPathComponent("repo-one").path))
        XCTAssertTrue(try branchExists(r1, "feat/midfail"))
        XCTAssertFalse(try branchExists(r2, "feat/midfail"))

        // User removes the blocker, then rolls back the partial creation.
        try FileManager.default.removeItem(at: blocker)
        let log = await service.rollback(report.artifacts)
        XCTAssertFalse(log.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: umbrella.appendingPathComponent("repo-one").path))
        XCTAssertFalse(try branchExists(r1, "feat/midfail"))
        // Now-empty umbrella was removed too.
        XCTAssertFalse(FileManager.default.fileExists(atPath: umbrella.path))
    }

    // MARK: - post-create hooks

    func testPostCreateHookRunsInNewWorktree() async throws {
        let report = await makeService().createWorkspace(
            project: makeProject(hooks: ["repo-one": "echo hello > marker.txt"]),
            name: "hooked", branch: "feat/hooked",
            repos: [repo1, repo2], forkFrom: nil)

        XCTAssertNil(report.failure)
        let marker = workspacesRoot.appendingPathComponent("hooked/repo-one/marker.txt")
        let content = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertEqual(content, "hello\n")
        XCTAssertTrue(report.logLines.contains { $0.contains("repo-one") })
        // No hook configured for repo-two -> no marker there.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspacesRoot.appendingPathComponent("hooked/repo-two/marker.txt").path))
    }

    func testFailingHookIsLoggedButDoesNotFailCreation() async throws {
        let report = await makeService().createWorkspace(
            project: makeProject(hooks: ["repo-one": "echo boom >&2; exit 1"]),
            name: "hookfail", branch: "feat/hookfail",
            repos: [repo1], forkFrom: nil)

        XCTAssertNil(report.failure)
        XCTAssertEqual(report.artifacts.count, 1)
        XCTAssertTrue(report.logLines.contains { $0.contains("exit") || $0.contains("boom") })
    }
}
