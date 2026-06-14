import XCTest
@testable import GroveCore

final class ConfigDecodeTests: XCTestCase {
    func testMinimalProjectJsonDecodesToDefaults() throws {
        let json = #"{"id":"B0000000-0000-0000-0000-000000000001","name":"p","path":"/p"}"#
        let p = try JSONDecoder().decode(ProjectConfig.self, from: Data(json.utf8))
        XCTAssertEqual(p.branchTemplate, "feat/{name}")
        XCTAssertEqual(p.scanDepth, 3)
        XCTAssertEqual(p.seedFiles, [])
        XCTAssertEqual(p.baseBranchOverrides, [:])
        XCTAssertEqual(p.postCreateHooks, [:])
        XCTAssertEqual(p.excludedRepos, [])
        XCTAssertNil(p.defaultAccount)
        XCTAssertNil(p.defaultModel)
        XCTAssertNil(p.defaultEffort)
        XCTAssertEqual(p.statsIgnoredFolders, [],
                       "statsIgnoredFolders must decode to [] when absent from old JSON")
    }

    func testMinimalAccountAndConfigDecodeToDefaults() throws {
        let acc = try JSONDecoder().decode(AccountConfig.self,
                                           from: Data(#"{"name":"work","configDir":"~/.x"}"#.utf8))
        XCTAssertFalse(acc.sharedStore)
        XCTAssertFalse(acc.monitoring)
        XCTAssertNil(acc.savedStatusline)
        XCTAssertNil(acc.defaultModel)

        let cfgJSON = #"{"version":1,"workspacesRootTemplate":"~/W/{project}","projects":[],"accounts":[]}"#
        let cfg = try JSONDecoder().decode(GroveConfig.self, from: Data(cfgJSON.utf8))
        XCTAssertEqual(cfg.usage.refreshSeconds, 15)        // usage absent -> defaults
        XCTAssertFalse(cfg.usage.oauthLiveEnabled)
    }

    func testFullRoundTripPreservesEveryField() throws {
        let project = ProjectConfig(
            name: "p", path: "/p", workspacesRoot: "/w", branchTemplate: "f/{name}",
            baseBranchOverrides: ["r": "dev"], postCreateHooks: ["r": "make"], excludedRepos: ["x"],
            scanDepth: 2, defaultAccount: "work",
            seedFiles: [SeedFile(source: "CLAUDE.md", mode: .copy, dest: .eachRepo)],
            defaultModel: "m", defaultEffort: "high",
            statsIgnoredFolders: ["vendor", "src/generated"])
        let cfg = GroveConfig(
            version: 1, workspacesRootTemplate: "~/W/{project}", projects: [project],
            accounts: [AccountConfig(name: "work", configDir: "~/.x", sharedStore: true,
                                     monitoring: true, savedStatusline: "orig",
                                     defaultModel: "m2", defaultEffort: "low")],
            usage: UsageSettings(refreshSeconds: 30, oauthLiveEnabled: true))
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(GroveConfig.self, from: data)
        XCTAssertEqual(back, cfg)
        XCTAssertEqual(GroveConfig.defaultConfig.accounts.first?.name, "default")
    }
}
