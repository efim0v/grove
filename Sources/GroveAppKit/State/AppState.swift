import Foundation
import SwiftUI
import GroveCore

public enum MainTab: String, CaseIterable {
    case workspaces
    case graph
    case accounts
}

/// Single observable source of truth for the app. Owns the config (loaded via
/// ConfigStore), per-project scan snapshots, selection, and every user action.
/// Action methods never throw into views: failures land in `actionError`.
@MainActor
public final class AppState: ObservableObject {
    @Published public var config: GroveConfig
    @Published public var configIssue: String?
    @Published public var snapshots: [UUID: ProjectSnapshot] = [:]
    @Published public var selectedProjectID: UUID?
    @Published public var selectedTab: MainTab = .workspaces
    @Published public var searchQuery: String = ""
    @Published public var isScanning: Bool = false
    @Published public var actionError: String?
    @Published public var graphRepoPath: String?
    @Published public var graphNodes: [CommitNode] = []

    private let configStore: ConfigStore

    /// Test seam: when set, every cmux interaction uses this service instead of
    /// a real `CmuxService()` (which would resolve and invoke the real cmux
    /// binary). Internal so GroveAppKitTests can inject via @testable import.
    internal var cmuxOverride: CmuxService?
    /// Test seam for CmuxService.claudeSessionWorkspaceMap(hookFile:); nil
    /// means the real ~/.cmuxterm/claude-hook-sessions.json.
    internal var cmuxHookFile: String?

    public init(configStore: ConfigStore) {
        self.configStore = configStore
        let loaded = configStore.load()
        self.config = loaded.config
        self.configIssue = loaded.issue
        self.selectedProjectID = loaded.config.projects.first?.id
    }

    /// Real config location: ~/Library/Application Support/Grove/config.json (spec §4).
    public convenience init() {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grove/config.json")
        self.init(configStore: ConfigStore(url: url))
    }

    // MARK: - Selection

    public var selectedProject: ProjectConfig? {
        config.projects.first { $0.id == selectedProjectID }
    }

    public var selectedSnapshot: ProjectSnapshot? {
        selectedProjectID.flatMap { snapshots[$0] }
    }

    // MARK: - Persistence

    private func persist() {
        do {
            try configStore.save(config)
        } catch {
            actionError = String(describing: error)
        }
    }

    // MARK: - Config CRUD

    /// Adds a project named after the path's leaf directory, saves and selects it.
    public func addProject(at path: String) {
        let expanded = expandTilde(path)
        let name = (expanded as NSString).lastPathComponent
        let project = ProjectConfig(name: name, path: expanded)
        config.projects.append(project)
        selectedProjectID = project.id
        persist()
    }

    public func removeProject(id: UUID) {
        config.projects.removeAll { $0.id == id }
        snapshots.removeValue(forKey: id)
        if selectedProjectID == id {
            selectedProjectID = config.projects.first?.id
        }
        persist()
    }

    /// Replaces the project with the same id; unknown ids are ignored.
    public func updateProject(_ p: ProjectConfig) {
        guard let index = config.projects.firstIndex(where: { $0.id == p.id }) else { return }
        config.projects[index] = p
        persist()
    }

    /// Global settings edit (SettingsSheet); persists like every other config mutation.
    public func setWorkspacesRootTemplate(_ template: String) {
        config.workspacesRootTemplate = template
        persist()
    }

    /// New account convention (spec §6.3): configDir = ~/.claude-accounts/<name>.
    public func addAccount(name: String) {
        guard !config.accounts.contains(where: { $0.name == name }) else {
            actionError = "account '\(name)' already exists"
            return
        }
        config.accounts.append(AccountConfig(name: name, configDir: "~/.claude-accounts/\(name)"))
        persist()
    }

    /// Removes the account from Grove's config only — the directory is untouched.
    public func removeAccount(name: String) {
        config.accounts.removeAll { $0.name == name }
        persist()
    }
}

// MARK: - Services & scanning

extension AppState {
    private func cmux() -> CmuxService {
        cmuxOverride ?? CmuxService()
    }

    /// Built fresh from the CURRENT config so edits (accounts, overrides, hooks)
    /// take effect on the next scan/creation without restarting.
    public var workspaceService: WorkspaceService {
        WorkspaceService(git: GitService(), claude: ClaudeService(), cmux: cmux(), config: config)
    }

    /// Scans the selected project; no-op when nothing is selected. scan() itself
    /// never throws (per-repo/cmux failures degrade into snapshot.errors).
    public func refresh() async {
        guard let project = selectedProject else { return }
        isScanning = true
        let snapshot = await workspaceService.scan(project: project)
        snapshots[project.id] = snapshot
        isScanning = false
    }
}

// MARK: - Graph

extension AppState {
    public func loadGraph(repoPath: String) async {
        graphRepoPath = repoPath
        do {
            graphNodes = try await GitService().commitGraph(repoPath: repoPath)
        } catch {
            graphNodes = []
            actionError = String(describing: error)
        }
    }
}

// MARK: - Claude / cmux actions

extension AppState {
    /// Launches Claude (optionally resuming a session) in a NEW cmux workspace
    /// at `cwd`, focused. cmux is started first when not running.
    public func launchClaude(cwd: String, title: String, account: AccountConfig,
                             resume sessionId: String?) async {
        let service = cmux()
        let command = ClaudeService.launchCommand(account: account, resume: sessionId)
        do {
            try await service.ensureRunning()
            try await service.newWorkspace(name: title, cwd: cwd, command: command, focus: true)
        } catch {
            actionError = String(describing: error)
        }
    }

    public func goToCmux(_ ws: CmuxWorkspace) async {
        do {
            try await cmux().selectWorkspace(ws.id)
        } catch {
            actionError = String(describing: error)
        }
    }

    /// Jumps to the cmux workspace hosting the session (via the hook registry);
    /// when unmapped, relaunches Claude with --resume in a fresh workspace.
    public func goToSession(_ s: ClaudeSession, fallbackCwd: String, fallbackTitle: String,
                            account: AccountConfig) async {
        let service = cmux()
        if let workspaceId = service.claudeSessionWorkspaceMap(hookFile: cmuxHookFile)[s.id] {
            do {
                try await service.selectWorkspace(workspaceId)
            } catch {
                actionError = String(describing: error)
            }
            return
        }
        await launchClaude(cwd: fallbackCwd, title: fallbackTitle, account: account, resume: s.id)
    }
}

// MARK: - Workspace creation

extension AppState {
    /// nil = no project selected. A report with a non-nil failure also sets
    /// actionError; the sheet additionally shows report.logLines.
    public func createWorkspace(name: String, branch: String, repos: [RepoInfo],
                                forkFrom: FeatureWorkspace?) async -> CreationReport? {
        guard let project = selectedProject else { return nil }
        let report = await workspaceService.createWorkspace(project: project, name: name,
                                                            branch: branch, repos: repos,
                                                            forkFrom: forkFrom)
        if let failure = report.failure {
            actionError = failure
        }
        return report
    }

    /// Removes ONLY the artifacts of a failed creation run (spec §5.4).
    public func rollback(_ artifacts: [CreatedArtifact]) async -> [String] {
        await workspaceService.rollback(artifacts)
    }
}
