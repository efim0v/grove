import XCTest
import GroveCore
@testable import GroveAppKit

/// AppState.loadBranches(for:): fills branchesByRepo (key = repo.path) from
/// real git repos via GitService.localBranches, replacing stale entries for
/// the scanned repos and leaving other keys alone.
@MainActor
final class AppStateBranchesTests: XCTestCase {
    private var root: URL!
    private var configURL: URL!

    override func setUp() async throws {
        root = try FixtureLite.tempDir("appstate-branches")
        configURL = root.appendingPathComponent("config.json")
    }

    private func makeState() -> AppState {
        let state = AppState(configStore: ConfigStore(url: configURL))
        state.cmuxOverride = stubbedCmux()
        return state
    }

    func testLoadBranchesFillsBranchesByRepoPerPath() async throws {
        let alpha = try FixtureLite.makeRepo(in: root, name: "alpha")
        try FixtureLite.sh("git branch dev && git branch feat/x", cwd: alpha)
        let beta = try FixtureLite.makeRepo(in: root, name: "beta", defaultBranch: "master")
        let state = makeState()

        await state.loadBranches(for: [RepoInfo(path: alpha.path, dirName: "alpha"),
                                       RepoInfo(path: beta.path, dirName: "beta")])

        XCTAssertEqual(state.branchesByRepo[alpha.path], ["dev", "feat/x", "main"])
        XCTAssertEqual(state.branchesByRepo[beta.path], ["master"])
    }

    func testLoadBranchesReplacesStaleEntriesAndKeepsOtherKeys() async throws {
        let alpha = try FixtureLite.makeRepo(in: root, name: "alpha")
        let state = makeState()
        state.branchesByRepo = [alpha.path: ["stale-branch"], "/other/repo": ["kept"]]

        await state.loadBranches(for: [RepoInfo(path: alpha.path, dirName: "alpha")])

        XCTAssertEqual(state.branchesByRepo[alpha.path], ["main"])
        XCTAssertEqual(state.branchesByRepo["/other/repo"], ["kept"])
    }

    func testLoadBranchesNonRepoDegradesToEmptyList() async throws {
        let notARepo = root.appendingPathComponent("plain-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
        let state = makeState()

        await state.loadBranches(for: [RepoInfo(path: notARepo.path, dirName: "plain-dir")])

        XCTAssertEqual(state.branchesByRepo[notARepo.path], [])
    }
}
