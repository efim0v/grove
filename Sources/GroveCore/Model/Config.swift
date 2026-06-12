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
    /// Account NAME from GroveConfig.accounts to use by default for this project.
    /// nil means "no preference" (fall back to whatever the caller decides).
    /// Backwards-compatible: old JSON without this key decodes to nil.
    public var defaultAccount: String?
    /// Files copied/symlinked from project.path into each new workspace.
    /// Back-compat: absent from old JSON decodes to [] (see init(from:)).
    public var seedFiles: [SeedFile]

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        workspacesRoot: String? = nil,
        branchTemplate: String = "feat/{name}",
        baseBranchOverrides: [String: String] = [:],
        postCreateHooks: [String: String] = [:],
        excludedRepos: [String] = [],
        scanDepth: Int = 3,
        defaultAccount: String? = nil,
        seedFiles: [SeedFile] = []
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
        self.defaultAccount = defaultAccount
        self.seedFiles = seedFiles
    }

    enum CodingKeys: String, CodingKey {
        case id, name, path, workspacesRoot, branchTemplate, baseBranchOverrides
        case postCreateHooks, excludedRepos, scanDepth, defaultAccount, seedFiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        workspacesRoot = try c.decodeIfPresent(String.self, forKey: .workspacesRoot)
        branchTemplate = try c.decodeIfPresent(String.self, forKey: .branchTemplate) ?? "feat/{name}"
        baseBranchOverrides = try c.decodeIfPresent([String: String].self, forKey: .baseBranchOverrides) ?? [:]
        postCreateHooks = try c.decodeIfPresent([String: String].self, forKey: .postCreateHooks) ?? [:]
        excludedRepos = try c.decodeIfPresent([String].self, forKey: .excludedRepos) ?? []
        scanDepth = try c.decodeIfPresent(Int.self, forKey: .scanDepth) ?? 3
        defaultAccount = try c.decodeIfPresent(String.self, forKey: .defaultAccount)
        seedFiles = try c.decodeIfPresent([SeedFile].self, forKey: .seedFiles) ?? []
    }
}

public enum SeedMode: String, Codable, Sendable { case symlink, copy }
public enum SeedDest: String, Codable, Sendable { case umbrella, eachRepo }

/// A file (relative to the project's containing directory) seeded into every
/// new workspace at creation time. `.umbrella` lands it at the workspace root
/// (where Claude's upward CLAUDE.md walk finds it); `.eachRepo` lands a copy in
/// every repo worktree. `.symlink` keeps a single source of truth; `.copy`
/// freezes a per-workspace snapshot.
public struct SeedFile: Codable, Sendable, Equatable {
    public var source: String
    public var mode: SeedMode
    public var dest: SeedDest

    public init(source: String, mode: SeedMode = .symlink, dest: SeedDest = .umbrella) {
        self.source = source
        self.mode = mode
        self.dest = dest
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
