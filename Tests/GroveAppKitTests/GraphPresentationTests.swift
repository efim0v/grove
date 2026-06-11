import XCTest
import GroveCore
import GroveAppKit

final class GraphPresentationTests: XCTestCase {

    // MARK: - refChips classification

    func testHeadArrowRefBecomesHeadChipWithBranch() {
        let chips = refChips(["HEAD -> dev"])
        XCTAssertEqual(chips, [RefChip(rawRef: "HEAD -> dev", kind: .head,
                                       name: "dev", branch: "dev")])
    }

    func testDetachedHeadHasNoBranchAction() {
        let chips = refChips(["HEAD"])
        XCTAssertEqual(chips, [RefChip(rawRef: "HEAD", kind: .head, name: "HEAD", branch: nil)])
    }

    func testTagRefStripsPrefixAndHasNoBranch() {
        let chips = refChips(["tag: v0.4.0"])
        XCTAssertEqual(chips, [RefChip(rawRef: "tag: v0.4.0", kind: .tag,
                                       name: "v0.4.0", branch: nil)])
    }

    func testRemoteRefKeepsPrefixInNameButStripsItFromBranch() {
        let chips = refChips(["origin/dev"])
        XCTAssertEqual(chips, [RefChip(rawRef: "origin/dev", kind: .remote,
                                       name: "origin/dev", branch: "dev")])
    }

    func testLocalBranchPassesThrough() {
        let chips = refChips(["feat/media-upload"])
        XCTAssertEqual(chips, [RefChip(rawRef: "feat/media-upload", kind: .local,
                                       name: "feat/media-upload", branch: "feat/media-upload")])
    }

    func testOrderPreservedAcrossMixedRefs() {
        let kinds = refChips(["HEAD -> dev", "origin/dev", "tag: v1", "main"]).map(\.kind)
        XCTAssertEqual(kinds, [.head, .remote, .tag, .local])
    }

    // MARK: - sanitizedWorkspaceName(fromBranch:)

    func testLeafComponentIsExtracted() {
        XCTAssertEqual(sanitizedWorkspaceName(fromBranch: "feat/media-upload"), "media-upload")
        XCTAssertEqual(sanitizedWorkspaceName(fromBranch: "release/1.2"), "1.2")
        XCTAssertEqual(sanitizedWorkspaceName(fromBranch: "main"), "main")
    }

    func testDisallowedCharactersBecomeDashes() {
        XCTAssertEqual(sanitizedWorkspaceName(fromBranch: "fix/PAY 12!"), "PAY-12-")
        XCTAssertEqual(sanitizedWorkspaceName(fromBranch: "фича"), "----")
    }

    func testDegenerateBranchFallsBackToWorkspace() {
        XCTAssertEqual(sanitizedWorkspaceName(fromBranch: "/"), "workspace")
        XCTAssertEqual(sanitizedWorkspaceName(fromBranch: ""), "workspace")
    }

    func testSanitizedNamesAlwaysPassTheCreateValidation() {
        for branch in ["feat/x", "weird name/with spaces", "a/b/c.d_e-f", "tag:like"] {
            XCTAssertNil(workspaceNameIssue(sanitizedWorkspaceName(fromBranch: branch)),
                         "branch \(branch) produced an invalid name")
        }
    }

    // MARK: - worktreeLocation(forBranch:in:) fixture

    private func snapshot() -> ProjectSnapshot {
        let repo = RepoInfo(path: "/p/app", dirName: "app")
        func repoState(branch: String, path: String) -> WorkspaceRepoState {
            WorkspaceRepoState(
                repo: repo,
                entry: WorktreeEntry(path: path, branch: branch, head: "abc", isMain: false),
                meta: nil, scanError: nil)
        }
        let ws = FeatureWorkspace(
            name: "media", umbrellaPath: "/ws/media",
            repos: [repoState(branch: "feat/media", path: "/ws/media/app")],
            parentName: nil, sessions: [], liveProcesses: [], cmuxWorkspaces: [])
        let loose = LooseWorktree(
            repo: repo,
            entry: WorktreeEntry(path: "/p/app/.worktrees/group-chats",
                                 branch: "feature/group-chats", head: "def", isMain: false),
            meta: nil, sessions: [], liveProcesses: [], cmuxWorkspaces: [])
        return ProjectSnapshot(project: ProjectConfig(name: "p", path: "/p"),
                               repos: [repo], workspaces: [ws], loose: [loose], errors: [])
    }

    func testWorkspaceBranchResolvesToUmbrella() {
        XCTAssertEqual(worktreeLocation(forBranch: "feat/media", in: snapshot()),
                       WorktreeLocation(cwd: "/ws/media", title: "media"))
    }

    func testLooseBranchResolvesToWorktreePathAndLeafTitle() {
        XCTAssertEqual(worktreeLocation(forBranch: "feature/group-chats", in: snapshot()),
                       WorktreeLocation(cwd: "/p/app/.worktrees/group-chats",
                                        title: "group-chats"))
    }

    func testUnknownBranchResolvesToNil() {
        XCTAssertNil(worktreeLocation(forBranch: "feat/nope", in: snapshot()))
    }
}
