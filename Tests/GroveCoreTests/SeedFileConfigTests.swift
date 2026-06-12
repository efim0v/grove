import XCTest
import GroveCore

final class SeedFileConfigTests: XCTestCase {
    // Old configs predate seedFiles; decoding must succeed with an empty list.
    func testSeedFilesDecodeToEmptyWhenAbsentFromOldJSON() throws {
        let json = """
        {
          "version": 1,
          "workspacesRootTemplate": "~/Workspaces/{project}",
          "projects": [
            {
              "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
              "name": "p",
              "path": "~/Desktop/p",
              "branchTemplate": "feat/{name}",
              "baseBranchOverrides": {},
              "postCreateHooks": {},
              "excludedRepos": [],
              "scanDepth": 3
            }
          ],
          "accounts": []
        }
        """
        let decoded = try JSONDecoder().decode(GroveConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.projects[0].seedFiles, [])
    }

    func testSeedFilesRoundTrip() throws {
        var project = ProjectConfig(name: "p", path: "/p")
        project.seedFiles = [
            SeedFile(source: "CLAUDE.md", mode: .symlink, dest: .umbrella),
            SeedFile(source: ".mcp.json", mode: .copy, dest: .eachRepo),
        ]
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: data)
        XCTAssertEqual(decoded.seedFiles, project.seedFiles)
    }

    func testSeedFileDefaultsAreSymlinkUmbrella() {
        let seed = SeedFile(source: "CLAUDE.md")
        XCTAssertEqual(seed.mode, .symlink)
        XCTAssertEqual(seed.dest, .umbrella)
    }

    func testSeedFilesDefaultEmptyOnNewProject() {
        XCTAssertEqual(ProjectConfig(name: "p", path: "/p").seedFiles, [])
    }
}
