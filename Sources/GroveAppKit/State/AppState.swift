import Foundation
import SwiftUI
import AppKit
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
    /// Per-account analytics (Task 3) + capture snapshots (Task 6), filled by
    /// refreshUsage on the scan tick. Empty until the first refresh.
    @Published public var usageByAccount: [String: AccountUsageAnalytics] = [:]
    @Published public var snapshotsByAccount: [String: [UsageSnapshot]] = [:]
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

    /// Test seam: the canonical store directory (the default `~/.claude`). nil
    /// means the real default — `$HOME/.claude`. PRODUCTION resolves the canonical
    /// dir to the real default account (`~/.claude`); TESTS MUST set this override
    /// (done in the suite's makeState/setUp) so linking never touches the real home.
    internal var canonicalDirOverride: String?

    /// Test seam: the pid-liveness predicate used by the concurrency guard. nil
    /// means the real check (pid alive AND its command mentions "claude"). Tests
    /// set { _ in true } so a fixture sessions/<pid>.json counts as live.
    internal var liveProcessValidatorOverride: ((Int32) -> Bool)?

    /// Test seam: the app-support dir the statusline wrapper script is shipped
    /// into. nil = the real ~/Library/Application Support/Grove/bin. TESTS set a
    /// temp dir so install never writes under the real app-support tree.
    internal var statuslineScriptDirOverride: String?

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
                             resume sessionId: String?,
                             model: String? = nil, effort: String? = nil) async {
        let service = cmux()
        let command = ClaudeService.launchCommand(account: account, resume: sessionId,
                                                  model: model, effort: effort)
        do {
            try await service.ensureRunning()
            try await service.newWorkspace(name: title, cwd: cwd, command: command, focus: true)
        } catch {
            actionError = String(describing: error)
        }
    }

    public func setProjectModel(projectID: UUID, model: String?) {
        guard let i = config.projects.firstIndex(where: { $0.id == projectID }) else { return }
        config.projects[i].defaultModel = (model?.isEmpty == true) ? nil : model
        persist()
    }
    public func setProjectEffort(projectID: UUID, effort: String?) {
        guard let i = config.projects.firstIndex(where: { $0.id == projectID }) else { return }
        config.projects[i].defaultEffort = (effort?.isEmpty == true) ? nil : effort
        persist()
    }

    /// Relaunches a session under `account` with an EXPLICIT model/effort (a session
    /// card's "Relaunch with model X"). Cross-account still link-on-demands via
    /// resumeSession's path; here we go straight to launch with the override.
    public func relaunchSession(_ session: ClaudeSession, as account: AccountConfig,
                                model: String?, effort: String?) async {
        let title = session.title ?? (session.cwd as NSString).lastPathComponent
        await launchClaude(cwd: session.cwd, title: title, account: account,
                           resume: session.id, model: model, effort: effort)
    }

    /// The project that owns `cwd` (its path or workspacesRoot is a prefix), if any.
    /// Used so a session's launch picks up the right project defaults.
    private func project(forCwd cwd: String) -> ProjectConfig? {
        let canon = canonicalPath(cwd)
        return config.projects.first { p in
            let roots = [expandTilde(p.path), expandTilde(p.workspacesRoot ?? "")]
                .filter { !$0.isEmpty }.map(canonicalPath)
            return roots.contains { canon == $0 || canon.hasPrefix($0 + "/") }
        }
    }

    /// Public resolver for the session cards: the project owning a session's cwd,
    /// so the model/effort pickers write that project's default (`setProjectModel`).
    public func owningProject(forCwd cwd: String) -> ProjectConfig? {
        project(forCwd: cwd)
    }

    /// Effective default model for a launch: project.defaultModel beats
    /// account.defaultModel beats nil (spec §C.6). cwd resolves the project.
    func effectiveModel(cwd: String, account: AccountConfig) -> String? {
        project(forCwd: cwd)?.defaultModel ?? account.defaultModel
    }

    func effectiveEffort(cwd: String, account: AccountConfig) -> String? {
        project(forCwd: cwd)?.defaultEffort ?? account.defaultEffort
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

    /// Jumps to the cmux workspace hosting the session. The Sessions table
    /// resolves the target workspace id when it builds the row (`cmuxWorkspaceId`
    /// — from the hook registry OR a cmux workspace already sitting in the
    /// session's cwd, which the spec's "Go" requires) and passes it as
    /// `workspaceId`. When nil, we re-resolve through the hook registry; only on
    /// a genuine miss do we relaunch Claude with --resume in a fresh workspace.
    public func goToSession(_ s: ClaudeSession, fallbackCwd: String, fallbackTitle: String,
                            account: AccountConfig, workspaceId: String? = nil) async {
        let service = cmux()
        if let id = workspaceId ?? service.claudeSessionWorkspaceMap(hookFile: cmuxHookFile)[s.id] {
            do {
                try await service.selectWorkspace(id)
            } catch {
                actionError = String(describing: error)
            }
            return
        }
        await launchClaude(cwd: fallbackCwd, title: fallbackTitle, account: account, resume: s.id)
    }

    /// The canonical store directory: the default account's `~/.claude` (or the
    /// test override). Linking roots here; it is never symlinked.
    private var canonicalDir: String {
        canonicalDirOverride ?? (NSHomeDirectory() + "/.claude")
    }

    /// The account whose expanded configDir IS the canonical dir, if configured.
    /// Sharing is impossible without it (nothing to root the symlinks at).
    private var canonicalAccount: AccountConfig? {
        config.accounts.first { expandTilde($0.configDir) == canonicalDir }
    }

    // MARK: - Shared store

    /// Links `account` into the canonical store (wholesale dirs only; per-workspace
    /// projects symlinks are created lazily on resume). Marks it sharedStore=true and
    /// persists. No-op for the canonical account. Failures land in actionError.
    public func linkAccount(_ account: AccountConfig) {
        guard canonicalAccount != nil else {
            actionError = "Can't link without a canonical account: add an account whose "
                + "config dir is ~/.claude (the default account)."
            return
        }
        guard expandTilde(account.configDir) != canonicalDir else { return }  // canonical: nothing to link
        let dir = expandTilde(account.configDir)
        // The account's CLAUDE_CONFIG_DIR must exist before its wholesale dirs can
        // be symlinked into canonical (createSymbolicLink needs a real parent).
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            _ = try SharedSessionStore().ensureLinked(accountDir: dir, canonicalDir: canonicalDir)
        } catch {
            actionError = "Couldn't link “\(account.name)”: \(error.localizedDescription)"
            return
        }
        if let index = config.accounts.firstIndex(where: { $0.name == account.name }),
           !config.accounts[index].sharedStore {
            config.accounts[index].sharedStore = true
            persist()
        }
    }

    /// Runs SharedSessionStore.verify across accounts MARKED sharedStore and
    /// surfaces the first issue through actionError (the existing banner). No
    /// issues → clears nothing (so it never stomps an unrelated error). Snapshot
    /// renders skip it (no real ~/.claude access).
    public func verifySharedStore() {
        let marked = config.accounts.filter(\.sharedStore).map { expandTilde($0.configDir) }
        guard !marked.isEmpty, canonicalAccount != nil else { return }
        let issues = SharedSessionStore().verify(accountDirs: marked, canonicalDir: canonicalDir)
        if let first = issues.first {
            actionError = "Shared store: \(first)"
        }
    }

    /// Links `account` into the canonical store unless it IS the canonical account
    /// (never linked to itself). Marks it sharedStore=true and persists. Returns
    /// nil on success, or an error message describing the failure (caller aborts).
    private func ensureLinkedForResume(_ account: AccountConfig, mangledCwd: String) -> String? {
        guard expandTilde(account.configDir) != canonicalDir else { return nil }  // canonical: skip
        let store = SharedSessionStore()
        let dir = expandTilde(account.configDir)
        // The account's CLAUDE_CONFIG_DIR must exist before its wholesale dirs can
        // be symlinked into canonical (createSymbolicLink needs a real parent).
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            _ = try store.ensureLinked(accountDir: dir, canonicalDir: canonicalDir)
            _ = try store.ensureWorkspaceLinked(accountDir: dir, canonicalDir: canonicalDir,
                                                mangledCwd: mangledCwd)
        } catch {
            return "Couldn't link “\(account.name)” to the shared store: \(error.localizedDescription)"
        }
        if let index = config.accounts.firstIndex(where: { $0.name == account.name }),
           !config.accounts[index].sharedStore {
            config.accounts[index].sharedStore = true
            persist()
        }
        return nil
    }

    /// The name of an account (other than `launchAccount`) under which `sessionId`
    /// has a live process, or nil. Used to BLOCK a cross-account launch that would
    /// have two processes writing one transcript (the one real corruption case).
    private func sessionLiveUnderOtherAccount(_ sessionId: String,
                                              launchAccount: AccountConfig) -> String? {
        let service = liveProcessValidatorOverride
            .map { ClaudeService().withProcessValidator($0) } ?? ClaudeService()
        for account in config.accounts where account.name != launchAccount.name {
            if service.liveProcesses(account: account).contains(where: { $0.sessionId == sessionId }) {
                return account.name
            }
        }
        return nil
    }

    /// Resumes `session` under `account`. Same-account: links nothing, just
    /// launches `--resume` in the session's cwd. Cross-account (D7, no copy): links
    /// BOTH the owning and the target account into the canonical store, so the
    /// transcript physically lives in canonical and is visible to the target, then
    /// launches `CLAUDE_CONFIG_DIR=<target> claude --resume <id>`. Aborts with an
    /// actionError (and launches nothing) when: there is no canonical/default
    /// account to root the share, the owning account is gone from config, linking
    /// fails, or the same session is live under a DIFFERENT account (concurrency
    /// guard, added in Task 4).
    public func resumeSession(_ session: ClaudeSession, as account: AccountConfig) async {
        if account.name != session.accountName {
            if let other = sessionLiveUnderOtherAccount(session.id, launchAccount: account) {
                actionError = "This session is live under “\(other)” — close it first, "
                    + "then resume as \(account.name)."
                return
            }
            guard canonicalAccount != nil else {
                actionError = "Can't share sessions without a canonical account: add an "
                    + "account whose config dir is ~/.claude (the default account)."
                return
            }
            guard let owner = config.accounts.first(where: { $0.name == session.accountName }) else {
                actionError = "Can't resume as \(account.name): the owning account "
                    + "“\(session.accountName)” is no longer configured."
                return
            }
            let mangled = ClaudeService.mangle(session.cwd)
            // Link the owner first (so the transcript migrates into canonical),
            // then the target (so the symlinked store makes it visible).
            if let error = ensureLinkedForResume(owner, mangledCwd: mangled) {
                actionError = error
                return
            }
            if let error = ensureLinkedForResume(account, mangledCwd: mangled) {
                actionError = error
                return
            }
        }
        let title = session.title ?? (session.cwd as NSString).lastPathComponent
        await launchClaude(cwd: session.cwd, title: title, account: account, resume: session.id,
                           model: effectiveModel(cwd: session.cwd, account: account),
                           effort: effectiveEffort(cwd: session.cwd, account: account))
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

// MARK: - Usage monitoring

extension AppState {
    private var statuslineScriptDir: String {
        statuslineScriptDirOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Grove/bin").path
    }

    /// Opens the account's config dir in Finder (`open <configDir>`). Snapshot-safe
    /// callers gate this off; production reveals the real dir.
    public func openConfigDir(_ account: AccountConfig) {
        NSWorkspace.shared.open(URL(fileURLWithPath: expandTilde(account.configDir)))
    }

    /// Installs the grove statusline wrapper for `account`, saving its prior
    /// command into AccountConfig.savedStatusline and marking monitoring=true.
    /// Failures land in actionError; nothing is mutated on failure.
    public func installMonitoring(_ account: AccountConfig) {
        let installer = StatuslineInstaller(scriptDir: statuslineScriptDir)
        let dir = expandTilde(account.configDir)
        let saved: String?
        do { saved = try installer.install(configDir: dir) }
        catch { actionError = "Couldn't enable monitoring for “\(account.name)”: \(error.localizedDescription)"; return }
        guard let i = config.accounts.firstIndex(where: { $0.name == account.name }) else { return }
        config.accounts[i].monitoring = true
        config.accounts[i].savedStatusline = saved
        persist()
    }

    /// Restores the saved original statusline command and clears monitoring.
    public func disableMonitoring(_ account: AccountConfig) {
        let installer = StatuslineInstaller(scriptDir: statuslineScriptDir)
        let dir = expandTilde(account.configDir)
        do { try installer.uninstall(configDir: dir, savedStatusline: account.savedStatusline) }
        catch { actionError = "Couldn't disable monitoring for “\(account.name)”: \(error.localizedDescription)"; return }
        guard let i = config.accounts.firstIndex(where: { $0.name == account.name }) else { return }
        config.accounts[i].monitoring = false
        config.accounts[i].savedStatusline = nil
        persist()
    }
}
