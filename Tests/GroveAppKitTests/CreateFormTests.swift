import XCTest
import GroveCore
@testable import GroveAppKit

final class CreateFormTests: XCTestCase {

    // MARK: workspaceNameIssue

    func testValidNamesPass() {
        XCTAssertNil(workspaceNameIssue("media-pipeline"))
        XCTAssertNil(workspaceNameIssue("a.b_c-2"))
    }

    func testEmptyNameAsksForInput() {
        XCTAssertEqual(workspaceNameIssue(""), "Enter a workspace name.")
    }

    func testInvalidCharactersAreRejected() {
        XCTAssertNotNil(workspaceNameIssue("bad name"))
        XCTAssertNotNil(workspaceNameIssue("slash/y"))
        XCTAssertNotNil(workspaceNameIssue("фича"))
    }

    // MARK: branchPreview

    func testBranchPreviewSubstitutesName() {
        XCTAssertEqual(branchPreview(template: "feat/{name}", name: "media"), "feat/media")
    }

    func testBranchPreviewWithoutPlaceholderIsUnchanged() {
        XCTAssertEqual(branchPreview(template: "develop", name: "media"), "develop")
    }

    // MARK: startPointCaption — fixture

    private let server = RepoInfo(path: "/p/server", dirName: "server")
    private let configA = RepoInfo(path: "/p/config-a", dirName: "config-a")
    private let client = RepoInfo(path: "/p/client", dirName: "client")
    private let fresh = RepoInfo(path: "/p/fresh", dirName: "fresh")

    private func meta(base: String) -> WorktreeMeta {
        WorktreeMeta(baseBranch: base, forkPoint: "f0", forkDate: nil,
                     ahead: 0, behind: 0, dirtyCount: 0,
                     lastCommitDate: nil, lastCommitSubject: nil)
    }

    private func repoState(_ repo: RepoInfo, branch: String, base: String) -> WorkspaceRepoState {
        WorkspaceRepoState(
            repo: repo,
            entry: WorktreeEntry(path: "/ws/parent/\(repo.dirName)", branch: branch,
                                 head: "abc123", isMain: false),
            meta: meta(base: base),
            scanError: nil)
    }

    private var parent: FeatureWorkspace {
        FeatureWorkspace(name: "parent", umbrellaPath: "/ws/parent",
                         repos: [repoState(server, branch: "feat/parent", base: "dev"),
                                 repoState(client, branch: "feat/parent", base: "master")],
                         parentName: nil, sessions: [], liveProcesses: [], cmuxWorkspaces: [])
    }

    private var snapshot: ProjectSnapshot {
        let project = ProjectConfig(name: "p", path: "/p",
                                    baseBranchOverrides: ["config-a": "docker"])
        return ProjectSnapshot(project: project,
                               repos: [server, configA, client, fresh],
                               workspaces: [parent], loose: [], errors: [])
    }

    // MARK: startPointCaption — cases

    func testForkFromUsesParentBranchInSharedRepo() {
        XCTAssertEqual(startPointCaption(repo: server, forkFrom: parent, base: nil, snapshot: snapshot),
                       "feat/parent")
    }

    func testForkFromFallsBackToBaseWhenParentLacksRepo() {
        XCTAssertEqual(startPointCaption(repo: configA, forkFrom: parent, base: nil, snapshot: snapshot),
                       "docker")
    }

    func testExplicitBaseHintWinsWithoutForkFrom() {
        XCTAssertEqual(startPointCaption(repo: server, forkFrom: nil, base: "release/1.2", snapshot: snapshot),
                       "release/1.2")
    }

    func testScanDerivedBaseBranch() {
        XCTAssertEqual(startPointCaption(repo: client, forkFrom: nil, base: nil, snapshot: snapshot),
                       "master")
    }

    func testUnknownRepoFallsBackToMain() {
        XCTAssertEqual(startPointCaption(repo: fresh, forkFrom: nil, base: nil, snapshot: snapshot),
                       "main")
    }
}
