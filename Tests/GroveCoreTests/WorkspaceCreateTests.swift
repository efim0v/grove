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
