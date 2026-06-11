import Foundation
import SwiftUI
import GroveCore

/// Capsule tab strip inside the project scope (Workspaces | Graph | Claude).
/// Accounts left the strip when it became its own Route (.accounts).
public enum MainTab: String, CaseIterable {
    case workspaces
    case graph
    case sessions

    /// Tab-strip label. `sessions` reads "Claude" (the strip is
    /// Workspaces | Graph | Claude).
    public var label: String {
        switch self {
        case .workspaces: return "Workspaces"
        case .graph: return "Graph"
        case .sessions: return "Claude"
        }
    }
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
    /// The panel's current full-screen state. Mutate via open()/goBack() so
    /// the transition direction and per-route side effects stay consistent.
    @Published public var route: Route = .projects
    /// Pending prefill for the createWorkspace route; producers set it right
    /// before open(.createWorkspace(id)), goBack() consumes it.
    @Published public var createPrefill: CreatePrefill?
    /// Direction of the LAST route change (push = forward, pop = backward),
    /// derived from route depth. Drives RootView's transition edges. Not
    /// @Published: it always changes together with `route`.
    public private(set) var routeIsForward = true
    /// The scan spawned by the last open(.project(id)); tests await it.
    internal var refreshTask: Task<Void, Never>?
    @Published public var searchQuery: String = ""
    @Published public var isScanning: Bool = false
    @Published public var actionError: String?
    @Published public var graphRepoPath: String?
    @Published public var graphNodes: [CommitNode] = []
    /// True when the last graph page came back full — drives the "Load more" row.
    @Published public var graphCanLoadMore: Bool = false
    /// Local branch names per repo (key = repo.path), filled by loadBranches.
    /// Branch pickers fall back to the resolved default while a repo is absent.
    @Published public var branchesByRepo: [String: [String]] = [:]

    private let configStore: ConfigStore

    /// Test seam: when set, every cmux interaction uses this service instead of
    /// a real `CmuxService()` (which would resolve and invoke the real cmux
    /// binary). Internal so GroveAppKitTests can inject via @testable import.
    internal var cmuxOverride: CmuxService?
    /// Test seam for CmuxService.claudeSessionWorkspaceMap(hookFile:); nil
    /// means the real ~/.cmuxterm/claude-hook-sessions.json.
    internal var cmuxHookFile: String?
    /// Graph page size (spec §6.2: 300). Internal so tests can page through a
    /// tiny fixture repo instead of building 300+ commits.
    internal var graphPageSize = 300

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

    // MARK: - Navigation (panel state machine)

    /// Navigates the panel. Pushes vs pops are classified by route depth
    /// (deeper-or-equal = forward). Opening a project selects it and kicks
    /// off a scan so the workspace tree is fresh by the time it settles.
    public func open(_ target: Route) {
        routeIsForward = target.depth >= route.depth
        if case .project(let id) = target {
            if id != selectedProjectID { resetGraph() }
            selectedProjectID = id
            refreshTask = Task { await self.refresh() }
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            route = target
        }
    }

    /// Pops along Route.backRoute. Leaving createWorkspace consumes the
    /// pending prefill so a later visit never reuses stale form state.
    public func goBack() {
        if case .createWorkspace = route { createPrefill = nil }
        open(route.backRoute)
    }

    // MARK: - Selection

    public var selectedProject: ProjectConfig? {
        config.projects.first { $0.id == selectedProjectID }
    }

    public var selectedSnapshot: ProjectSnapshot? {
        selectedProjectID.flatMap { snapshots[$0] }
    }

    /// Account a single-click "New Claude" launches on (spec §6.1): the
    /// selected project's defaultAccount when it names a configured account,
    /// else the first account. The account MENUS always list all accounts.
    public var defaultLaunchAccount: AccountConfig? {
        if let name = selectedProject?.defaultAccount,
           let account = config.accounts.first(where: { $0.name == name }) {
            return account
        }
        return config.accounts.first
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
            resetGraph()
        }
        persist()
    }

    /// Replaces the project with the same id; unknown ids are ignored.
    public func updateProject(_ p: ProjectConfig) {
        guard let index = config.projects.firstIndex(where: { $0.id == p.id }) else { return }
        config.projects[index] = p
        persist()
    }

    /// Global settings edit (GlobalSettingsScreen); persists like every other config mutation.
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

    /// Refreshes branchesByRepo for `repos`, concurrently (one git call per
    /// repo). Existing entries for these repos are REPLACED — a deleted branch
    /// disappears from the pickers on the next load — while entries for other
    /// repos are left alone. localBranches never throws ([] on failure), so
    /// non-repos degrade to an empty list and the pickers fall back to the
    /// resolved default.
    public func loadBranches(for repos: [RepoInfo]) async {
        let fresh = await withTaskGroup(of: (String, [String]).self) { group in
            for repo in repos {
                group.addTask { [path = repo.path] in
                    (path, await GitService().localBranches(repoPath: path))
                }
            }
            var collected: [String: [String]] = [:]
            for await (path, branches) in group {
                collected[path] = branches
            }
            return collected
        }
        branchesByRepo.merge(fresh) { _, new in new }
    }
}

// MARK: - Graph

extension AppState {
    /// Drops the loaded graph page. Called whenever the selected project
    /// changes (open(.project) with a different id, removeProject of the
    /// selected one): graphNodes/graphRepoPath belong to ONE project, and
    /// keeping them across a switch rendered project A's commits under
    /// project B's repo strip (v1.2.1 fix 1). GraphScreen auto-selects the
    /// new project's first repo via graphAutoSelectRepo on its next .task.
    private func resetGraph() {
        graphNodes = []
        graphRepoPath = nil
        graphCanLoadMore = false
    }

    public func loadGraph(repoPath: String) async {
        graphRepoPath = repoPath
        do {
            graphNodes = try await GitService().commitGraph(repoPath: repoPath, limit: graphPageSize)
            graphCanLoadMore = graphNodes.count == graphPageSize
        } catch {
            graphNodes = []
            graphCanLoadMore = false
            actionError = String(describing: error)
        }
    }

    /// Appends the next `git log --all` page (spec §6.2 lazy paging). No-op
    /// when the previous page was short. Commits created between page loads
    /// shift skip-based ordering, so a page can repeat already-loaded hashes —
    /// those are dropped (graphNodes hashes must stay unique: they are ForEach
    /// identities and GraphLanesCanvas row keys). KNOWN v1 LIMITATION:
    /// commitGraph lays lanes out per page, so lane numbers (and colors)
    /// restart at each page boundary; links inside a page stay correct.
    public func loadMoreGraph() async {
        guard let repoPath = graphRepoPath, graphCanLoadMore else { return }
        do {
            let more = try await GitService().commitGraph(repoPath: repoPath,
                                                          limit: graphPageSize,
                                                          skip: graphNodes.count)
            let seen = Set(graphNodes.map(\.hash))
            graphNodes += more.filter { !seen.contains($0.hash) }
            graphCanLoadMore = more.count == graphPageSize
        } catch {
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

    /// Degraded-mode affordance (spec §7): the error banner's "Launch cmux"
    /// button. ensureRunning performs `open -b com.cmuxterm.app` and waits for
    /// a ping answer; success clears the banner, failure replaces it.
    public func launchCmuxApp() async {
        do {
            try await cmux().ensureRunning()
            actionError = nil
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

    /// Resumes `session` under `account` (Sessions tab "Resume" / "Resume as
    /// <name>"). When `account` differs from the session's owning account, the
    /// feasibility experiment (verdict: FEASIBLE) lets us make it resumable by
    /// copying the transcript into the target account's identical projects path
    /// first — the lookup layer resolves the copied jsonl; auth comes from the
    /// target account's keychain at runtime. Same-account resume copies nothing.
    /// A copy failure lands in actionError and aborts the launch.
    public func resumeSession(_ session: ClaudeSession, as account: AccountConfig) async {
        if account.name != session.accountName,
           let source = config.accounts.first(where: { $0.name == session.accountName }) {
            do {
                try ClaudeService().copySession(session, from: source, to: account)
            } catch {
                actionError = String(describing: error)
                return
            }
        }
        let title = session.title ?? (session.cwd as NSString).lastPathComponent
        await launchClaude(cwd: session.cwd, title: title, account: account, resume: session.id)
    }
}

// MARK: - Workspace creation

extension AppState {
    /// nil = no project selected. A report with a non-nil failure also sets
    /// actionError; the create screen additionally shows report.logLines.
    /// startPointOverrides (keyed by repo dirName) beat both the resolved base
    /// branch and any fork-from parent branch — see WorkspaceService.
    public func createWorkspace(name: String, branch: String, repos: [RepoInfo],
                                forkFrom: FeatureWorkspace?,
                                startPointOverrides: [String: String] = [:]) async -> CreationReport? {
        guard let project = selectedProject else { return nil }
        let report = await workspaceService.createWorkspace(project: project, name: name,
                                                            branch: branch, repos: repos,
                                                            forkFrom: forkFrom,
                                                            startPointOverrides: startPointOverrides)
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

// MARK: - cmux shell fallback (spec §6.1)

extension AppState {
    /// Creates a NEW shell-only cmux workspace at `cwd` and focuses it — the
    /// cmux-button fallback when a workspace has no cmux workspace yet.
    /// `command: nil` means cmux starts its default shell.
    public func openCmuxShell(cwd: String, title: String) async {
        let service = cmux()
        do {
            try await service.ensureRunning()
            try await service.newWorkspace(name: title, cwd: cwd, command: nil, focus: true)
        } catch {
            actionError = String(describing: error)
        }
    }
}
