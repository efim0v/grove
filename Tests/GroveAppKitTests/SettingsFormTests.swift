import XCTest
import GroveCore
@testable import GroveAppKit

final class SettingsFormTests: XCTestCase {
    private let server = RepoInfo(path: "/p/server", dirName: "server")
    private let client = RepoInfo(path: "/p/client", dirName: "client")

    private func snapshot(repos: [RepoInfo]) -> ProjectSnapshot {
        ProjectSnapshot(project: ProjectConfig(name: "p", path: "/p"),
                        repos: repos, workspaces: [], loose: [], errors: [])
    }

    func testRowsComeFromSnapshotReposSortedByDirName() {
        let rows = overrideEditorRows(snapshot: snapshot(repos: [server, client]),
                                      overrides: [:])
        XCTAssertEqual(rows, [OverrideEditorRow(dirName: "client", repoPath: "/p/client"),
                              OverrideEditorRow(dirName: "server", repoPath: "/p/server")])
    }

    func testOverrideKeysWithoutMatchingRepoStayVisibleWithoutAPath() {
        let rows = overrideEditorRows(snapshot: snapshot(repos: [server]),
                                      overrides: ["server": "dev", "gone-repo": "docker"])
        XCTAssertEqual(rows, [OverrideEditorRow(dirName: "gone-repo", repoPath: nil),
                              OverrideEditorRow(dirName: "server", repoPath: "/p/server")])
    }

    func testWithoutSnapshotRowsFallBackToDictKeys() {
        let rows = overrideEditorRows(snapshot: nil, overrides: ["b": "x", "a": "y"])
        XCTAssertEqual(rows, [OverrideEditorRow(dirName: "a", repoPath: nil),
                              OverrideEditorRow(dirName: "b", repoPath: nil)])
    }

    func testNoSnapshotNoOverridesYieldsNoRows() {
        XCTAssertTrue(overrideEditorRows(snapshot: nil, overrides: [:]).isEmpty)
    }
}
