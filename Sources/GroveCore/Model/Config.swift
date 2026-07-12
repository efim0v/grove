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
    public var defaultModel: String?
    public var defaultEffort: String?
    /// Accent color for this project (hex like "#34C759"), shown on the project
    /// name and its workspaces so projects are easy to tell apart. nil = derive a
    /// stable default from the project id. Back-compat: absent from old JSON → nil.
    public var accentColor: String?
    /// Project-root-relative folder paths excluded from code-stats scans (in
    /// addition to `.gitignore` / `.ignorestats` and the always-skipped dirs).
    /// Back-compat: absent from old JSON decodes to [] (see init(from:)).
    public var statsIgnoredFolders: [String]
    /// Launch every Claude session for this project (new AND resume) with
    /// `--dangerously-skip-permissions`, for fully-autonomous agents that must not
    /// stop for per-command confirmations. OFF by default (the flag is dangerous —
    /// it disables Claude's tool-permission gating). Back-compat: absent from old
    /// JSON decodes to false (see init(from:)).
    public var dangerouslySkipPermissions: Bool

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
        seedFiles: [SeedFile] = [],
        defaultModel: String? = nil,
        defaultEffort: String? = nil,
        accentColor: String? = nil,
        statsIgnoredFolders: [String] = [],
        dangerouslySkipPermissions: Bool = false
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
        self.defaultModel = defaultModel
        self.defaultEffort = defaultEffort
        self.accentColor = accentColor
        self.statsIgnoredFolders = statsIgnoredFolders
        self.dangerouslySkipPermissions = dangerouslySkipPermissions
    }

    enum CodingKeys: String, CodingKey {
        case id, name, path, workspacesRoot, branchTemplate, baseBranchOverrides
        case postCreateHooks, excludedRepos, scanDepth, defaultAccount, seedFiles
        case defaultModel, defaultEffort, accentColor, statsIgnoredFolders
        case dangerouslySkipPermissions
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
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        defaultEffort = try c.decodeIfPresent(String.self, forKey: .defaultEffort)
        accentColor = try c.decodeIfPresent(String.self, forKey: .accentColor)
        statsIgnoredFolders = try c.decodeIfPresent([String].self, forKey: .statsIgnoredFolders) ?? []
        dangerouslySkipPermissions = try c.decodeIfPresent(Bool.self, forKey: .dangerouslySkipPermissions) ?? false
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

/// Global usage subsystem settings (spec §6). `refreshSeconds` is the scan-tick
/// cadence for reading capture snapshots / analytics; `oauthLiveEnabled` gates
/// the fragile, undocumented OAuth usage poll (§C.4) — OFF by default.
public struct UsageSettings: Codable, Sendable, Equatable {
    public var refreshSeconds: Int
    public var oauthLiveEnabled: Bool

    public init(refreshSeconds: Int = 15, oauthLiveEnabled: Bool = false) {
        self.refreshSeconds = refreshSeconds
        self.oauthLiveEnabled = oauthLiveEnabled
    }

    enum CodingKeys: String, CodingKey { case refreshSeconds, oauthLiveEnabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refreshSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? 15
        oauthLiveEnabled = try c.decodeIfPresent(Bool.self, forKey: .oauthLiveEnabled) ?? false
    }
}

/// Transcript safety-net settings. grove hardlink-mirrors every session
/// transcript and auto-restores any unlink'd out-of-band; `maxDays`/`maxMB` bound
/// the mirror. Back-compat: absent from old JSON decodes to defaults.
public struct TranscriptMirrorSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var maxDays: Int
    public var maxMB: Int

    public init(enabled: Bool = true, maxDays: Int = 90, maxMB: Int = 500) {
        self.enabled = enabled; self.maxDays = maxDays; self.maxMB = maxMB
    }

    enum CodingKeys: String, CodingKey { case enabled, maxDays, maxMB }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        maxDays = try c.decodeIfPresent(Int.self, forKey: .maxDays) ?? 90
        maxMB   = try c.decodeIfPresent(Int.self, forKey: .maxMB) ?? 500
    }
}

public struct AccountConfig: Codable, Sendable, Equatable {
    public var name: String
    public var configDir: String
    /// True when this account's session stores are symlinked into the canonical
    /// (default `~/.claude`) account. The canonical/default account is implicitly
    /// canonical and is never marked shared. Back-compat: absent from old JSON
    /// decodes to false (see init(from:)).
    public var sharedStore: Bool
    public var monitoring: Bool
    /// True when the user explicitly disabled monitoring via the UI toggle.
    /// Distinguishes "user turned it off" from "never enabled" so that
    /// reconcileMonitoring does not silently re-enable an account the user
    /// deliberately disabled. Back-compat: absent from old JSON decodes to false.
    public var monitoringDisabledByUser: Bool
    public var savedStatusline: String?
    public var defaultModel: String?
    public var defaultEffort: String?

    public init(
        name: String,
        configDir: String,
        sharedStore: Bool = false,
        monitoring: Bool = false,
        monitoringDisabledByUser: Bool = false,
        savedStatusline: String? = nil,
        defaultModel: String? = nil,
        defaultEffort: String? = nil
    ) {
        self.name = name
        self.configDir = configDir
        self.sharedStore = sharedStore
        self.monitoring = monitoring
        self.monitoringDisabledByUser = monitoringDisabledByUser
        self.savedStatusline = savedStatusline
        self.defaultModel = defaultModel
        self.defaultEffort = defaultEffort
    }

    enum CodingKeys: String, CodingKey {
        case name, configDir, sharedStore
        case monitoring, monitoringDisabledByUser, savedStatusline, defaultModel, defaultEffort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        configDir = try c.decode(String.self, forKey: .configDir)
        sharedStore = try c.decodeIfPresent(Bool.self, forKey: .sharedStore) ?? false
        monitoring = try c.decodeIfPresent(Bool.self, forKey: .monitoring) ?? false
        monitoringDisabledByUser = try c.decodeIfPresent(Bool.self, forKey: .monitoringDisabledByUser) ?? false
        savedStatusline = try c.decodeIfPresent(String.self, forKey: .savedStatusline)
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        defaultEffort = try c.decodeIfPresent(String.self, forKey: .defaultEffort)
    }
}

public struct GroveConfig: Codable, Sendable, Equatable {
    public var version: Int
    public var workspacesRootTemplate: String
    public var projects: [ProjectConfig]
    public var accounts: [AccountConfig]
    /// Usage subsystem settings (spec §6). Back-compat: absent from old JSON
    /// decodes to UsageSettings() defaults (see init(from:)).
    public var usage: UsageSettings
    public var transcriptMirror: TranscriptMirrorSettings

    public init(
        version: Int,
        workspacesRootTemplate: String,
        projects: [ProjectConfig],
        accounts: [AccountConfig],
        usage: UsageSettings = UsageSettings(),
        transcriptMirror: TranscriptMirrorSettings = TranscriptMirrorSettings()
    ) {
        self.version = version
        self.workspacesRootTemplate = workspacesRootTemplate
        self.projects = projects
        self.accounts = accounts
        self.usage = usage
        self.transcriptMirror = transcriptMirror
    }

    enum CodingKeys: String, CodingKey {
        case version, workspacesRootTemplate, projects, accounts, usage, transcriptMirror
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        workspacesRootTemplate = try c.decode(String.self, forKey: .workspacesRootTemplate)
        projects = try c.decode([ProjectConfig].self, forKey: .projects)
        accounts = try c.decode([AccountConfig].self, forKey: .accounts)
        usage = try c.decodeIfPresent(UsageSettings.self, forKey: .usage) ?? UsageSettings()
        transcriptMirror = try c.decodeIfPresent(TranscriptMirrorSettings.self, forKey: .transcriptMirror) ?? TranscriptMirrorSettings()
    }

    public static let defaultConfig = GroveConfig(
        version: 1,
        workspacesRootTemplate: "~/Workspaces/{project}",
        projects: [],
        accounts: [AccountConfig(name: "default", configDir: "~/.claude")]
    )
}
