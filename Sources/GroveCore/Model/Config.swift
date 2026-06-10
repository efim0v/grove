import Foundation

public struct ProjectConfig: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var path: String
    public var workspacesRoot: String?
    public var branchTemplate: String
    public var baseBranchOverrides: [String: String]
    public var postCreateHooks: [String: String]
    public var excludedRepos: [String]
    public var scanDepth: Int

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        workspacesRoot: String? = nil,
        branchTemplate: String = "feat/{name}",
        baseBranchOverrides: [String: String] = [:],
        postCreateHooks: [String: String] = [:],
        excludedRepos: [String] = [],
        scanDepth: Int = 3
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.workspacesRoot = workspacesRoot
        self.branchTemplate = branchTemplate
        self.baseBranchOverrides = baseBranchOverrides
        self.postCreateHooks = postCreateHooks
        self.excludedRepos = excludedRepos
        self.scanDepth = scanDepth
    }
}

public struct AccountConfig: Codable, Sendable, Equatable {
    public var name: String
    public var configDir: String

    public init(name: String, configDir: String) {
        self.name = name
        self.configDir = configDir
    }
}

public struct GroveConfig: Codable, Sendable, Equatable {
    public var version: Int
    public var workspacesRootTemplate: String
    public var projects: [ProjectConfig]
    public var accounts: [AccountConfig]

    public init(
        version: Int,
        workspacesRootTemplate: String,
        projects: [ProjectConfig],
        accounts: [AccountConfig]
    ) {
        self.version = version
        self.workspacesRootTemplate = workspacesRootTemplate
        self.projects = projects
        self.accounts = accounts
    }

    public static let defaultConfig = GroveConfig(
        version: 1,
        workspacesRootTemplate: "~/Workspaces/{project}",
        projects: [],
        accounts: [AccountConfig(name: "default", configDir: "~/.claude")]
    )
}
