import XCTest
@testable import GroveCore

final class WorkspaceSeedTests: XCTestCase {
    var baseDir: URL!
    var projectDir: URL!
    var workspacesRoot: URL!
    var r1: URL!
    var r2: URL!

    override func setUpWithError() throws {
        baseDir = try Fixture.tempDir("seed")
        projectDir = baseDir.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        r1 = try Fixture.makeRepo(in: projectDir, name: "repo-one")
        r2 = try Fixture.makeRepo(in: projectDir, name: "repo-two")
        workspacesRoot = baseDir.appendingPathComponent("workspaces")
    }

    private func makeProject(seedFiles: [SeedFile]) -> ProjectConfig {
        ProjectConfig(name: "proj", path: projectDir.path,
                      workspacesRoot: workspacesRoot.path, seedFiles: seedFiles)
    }

    private func makeService() -> WorkspaceService {
        WorkspaceService(git: GitService(), claude: ClaudeService(), cmux: CmuxService(),
                         config: GroveConfig.defaultConfig)
    }

    private var repo1: RepoInfo { RepoInfo(path: r1.path, dirName: "repo-one") }
    private var repo2: RepoInfo { RepoInfo(path: r2.path, dirName: "repo-two") }

    private func writeSeedSource(_ name: String, _ content: String) throws {
        try content.write(to: projectDir.appendingPathComponent(name),
                          atomically: true, encoding: .utf8)
    }

    func testSeedCopiedIntoUmbrella() async throws {
        try writeSeedSource("CLAUDE.md", "umbrella memory\n")
        let report = await makeService().createWorkspace(
            project: makeProject(seedFiles: [SeedFile(source: "CLAUDE.md", mode: .copy, dest: .umbrella)]),
            name: "delta", branch: "feat/delta", repos: [repo1], forkFrom: nil)

        XCTAssertNil(report.failure)
        let dst = workspacesRoot.appendingPathComponent("delta/CLAUDE.md")
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "umbrella memory\n")
        // .copy is a real file, not a symlink.
        let attrs = try FileManager.default.attributesOfItem(atPath: dst.path)
        XCTAssertNotEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    func testSeedSymlinkedIntoUmbrellaPointsAtSource() async throws {
        try writeSeedSource("CLAUDE.md", "shared memory\n")
        let report = await makeService().createWorkspace(
            project: makeProject(seedFiles: [SeedFile(source: "CLAUDE.md", mode: .symlink, dest: .umbrella)]),
            name: "delta", branch: "feat/delta", repos: [repo1], forkFrom: nil)

        XCTAssertNil(report.failure)
        let dst = workspacesRoot.appendingPathComponent("delta/CLAUDE.md").path
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: dst)
        XCTAssertEqual(target, projectDir.appendingPathComponent("CLAUDE.md").path)
        // Reads through the link.
        XCTAssertEqual(try String(contentsOfFile: dst, encoding: .utf8), "shared memory\n")
    }

    func testSeedEachRepoLandsInEveryWorktree() async throws {
        try writeSeedSource(".mcp.json", "{}\n")
        let report = await makeService().createWorkspace(
            project: makeProject(seedFiles: [SeedFile(source: ".mcp.json", mode: .copy, dest: .eachRepo)]),
            name: "delta", branch: "feat/delta", repos: [repo1, repo2], forkFrom: nil)

        XCTAssertNil(report.failure)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workspacesRoot.appendingPathComponent("delta/repo-one/.mcp.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workspacesRoot.appendingPathComponent("delta/repo-two/.mcp.json").path))
    }

    func testMissingSeedSourceIsNonFatalAndLogged() async throws {
        let report = await makeService().createWorkspace(
            project: makeProject(seedFiles: [SeedFile(source: "NOPE.md", mode: .copy, dest: .umbrella)]),
            name: "delta", branch: "feat/delta", repos: [repo1], forkFrom: nil)

        XCTAssertNil(report.failure)                 // creation still succeeds
        XCTAssertEqual(report.artifacts.count, 1)
        XCTAssertTrue(report.logLines.contains { $0.contains("NOPE.md") })
    }

    func testExistingDestinationIsNotOverwritten() async throws {
        try writeSeedSource("CLAUDE.md", "from project\n")
        // Pre-create the umbrella with a different CLAUDE.md already present.
        let umbrella = workspacesRoot.appendingPathComponent("delta")
        try FileManager.default.createDirectory(at: umbrella, withIntermediateDirectories: true)
        try "preexisting\n".write(to: umbrella.appendingPathComponent("CLAUDE.md"),
                                  atomically: true, encoding: .utf8)

        let report = await makeService().createWorkspace(
            project: makeProject(seedFiles: [SeedFile(source: "CLAUDE.md", mode: .copy, dest: .umbrella)]),
            name: "delta", branch: "feat/delta", repos: [repo1], forkFrom: nil)

        XCTAssertNil(report.failure)
        XCTAssertEqual(try String(contentsOf: umbrella.appendingPathComponent("CLAUDE.md"),
                                  encoding: .utf8), "preexisting\n")
    }
}
