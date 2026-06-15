import Foundation
import SwiftUI
import AppKit
import GroveCore

/// Capsule tab strip inside the project scope (Workspaces | Graph | Claude).
/// Accounts left the strip when it became its own Route (.accounts).
public enum MainTab: String, CaseIterable {
    case workspaces
    case graph
    case stats
    case sessions

    /// Tab-strip label. `sessions` reads "Claude" (the strip is
    /// Workspaces | Graph | Stats | Claude).
    public var label: String {
        switch self {
        case .workspaces: return "Workspaces"
        case .graph: return "Graph"
        case .stats: return "Stats"
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
    /// Per-project recent Claude sessions (item 4): the Projects tab's previews.
    /// Filled by refreshSessionIndex (cheap, off-main — no git scan).
    @Published public var recentSessionsByProject: [UUID: [ProjectSessionRow]] = [:]
    /// Which scope the embedded charts section shows (0 = Overall when >1 account, else the
    /// first account). The ‹ › arrows step this; persisted so it survives panel reopen.
    @Published public var chartsScopeIndex: Int = 0
    /// Whether the charts (account-stats) section is shown alongside the projects
    /// section in the single merged window. The collapse toggle in RootShell flips
    /// it; when false the window becomes projects-only width. In-memory for now
    /// (persisting would mutate GroveConfig — a follow-up).
    @Published public var showCharts: Bool = true
    /// When non-nil, the launch sheet is presented to configure a Resume/New launch
    /// (open-target, account, model, effort) before it runs.
    @Published public var launchRequest: LaunchRequest?
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
    /// True only while the menu-bar panel is actually open. The controller sets it
    /// on show/hide; RootView's 15s refresh loop is keyed on it so the loop never
    /// runs while the panel is hidden (or in a headless render/test) — which would
    /// otherwise spin forever parsing real transcripts (the menu-bar panel hides
    /// via orderOut, which does NOT deallocate the view or cancel its .task).
    @Published public var isPanelOpen: Bool = false
    @Published public var isScanning: Bool = false
    @Published public var actionError: String?
    @Published public var graphRepoPath: String?
    @Published public var graphNodes: [CommitNode] = []
    /// True when the last graph page came back full — drives the "Load more" row.
    @Published public var graphCanLoadMore: Bool = false
    /// The commit whose file changes are expanded inline, and the lazily-loaded
    /// list (nil while loading). Tapping the same commit collapses it.
    @Published public var expandedCommit: String?
    @Published public var expandedCommitFiles: [CommitFileChange]?
    /// Local branch names per repo (key = repo.path), filled by loadBranches.
    /// Branch pickers fall back to the resolved default while a repo is absent.
    @Published public var branchesByRepo: [String: [String]] = [:]
    /// Stats-tab per-repo branch override (key = repo.path → chosen branch). Repo paths
    /// are unique across projects, so a flat dict is fine. Empty ⇒ each repo uses its
    /// auto-detected default. Fed into GitStatsService.scan as `branchOverrides`; an
    /// override that no longer names a real branch is silently ignored by the engine.
    @Published public var selectedStatsBranchByRepo: [String: String] = [:]

    /// Per-project code-stats snapshot (Stage 4), filled lazily by refreshCodeStats
    /// from the stats screen's .task (NOT the global refresh). Empty until scanned.
    @Published public var codeStats: [UUID: CodeStats] = [:]
    /// Per-project code-stats history (the "lines over time" series). Now GIT-derived:
    /// `refreshCodeStats` OVERWRITES it each scan with the per-day cumulative net-lines
    /// series summed across the project's repos (no longer an append-only snapshot log).
    @Published public var codeStatsHistory: [UUID: [CodeStatsPoint]] = [:]
    /// Per-project per-repo breakdown (current LOC + history + delta per repo), produced
    /// alongside the aggregate by GitStatsService. Published for a LATER per-repo UI pass;
    /// the current screen reads only `codeStats`/`codeStatsHistory`.
    @Published public var repoStats: [UUID: [RepoStats]] = [:]
    /// Per-project per-file list (project-root-relative path + classified line total +
    /// language), produced by the same scan that fills `codeStats`. Feeds the stats
    /// settings page's directory+file tree; honors the folder/.ignorestats exclusions.
    @Published public var statsFiles: [UUID: [StatFileEntry]] = [:]
    /// True only while a code-stats scan is in flight (drives the screen's spinner).
    @Published public var isStatsScanning: Bool = false

    private let configStore: ConfigStore

    /// Persistent service instances. Their mtime parse-caches MUST survive across
    /// scans/refreshes — a fresh `ClaudeService()`/`UsageAnalytics()` per tick
    /// re-parsed every transcript from scratch on the 15s loop (item 2 perf bug).
    private let claude = ClaudeService()
    private let usageAnalytics = UsageAnalytics()

    /// Git-as-source-of-truth code-stats service (per-repo, honors .gitignore via git's
    /// own engine, excludes worktrees). Stateless value type; the per-project/per-repo
    /// file cache below survives across refreshes so steady-state scans only re-read
    /// changed files. Replaces the old filesystem-walk scanner for the stats numbers.
    private let gitStats = GitStatsService()
    /// Retained ONLY for `statsDirectoryTree` (the folder-exclusion picker still walks
    /// the directory skeleton via this; its `scan` is no longer used for the numbers).
    private let statsScanner = CodeStatsScanner()
    /// Per-project git-stats file cache, keyed by project UUID then repo path. Mutated
    /// only on the main actor (the detached scan takes a COPY of the relevant project's
    /// cache and returns the updated one — same pattern as refreshUsage's off-main work).
    private var gitStatsCacheByProject: [UUID: [String: RepoFileCache]] = [:]
    /// Per-project scan serialization. Two scans of the SAME project must never run
    /// concurrently: both would start from the same cache snapshot and the slower one
    /// would overwrite the faster's cache on completion, silently dropping mtime
    /// entries (so the next scan needlessly re-reads those files). A project in
    /// `statsScanInFlight` has a scan running; a refresh requested meanwhile records
    /// `statsRescanPending` and is honored once the in-flight scan settles.
    private var statsScanInFlight: Set<UUID> = []
    private var statsRescanPending: Set<UUID> = []

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

    /// Test seam: the directory the per-project code-stats history files live in.
    /// nil = the real ~/Library/Application Support/Grove/stats. TESTS set a temp
    /// dir so history persistence never writes under the real app-support tree.
    internal var statsStoreDirOverride: String?

    /// Test seam: account tiers (organizationRateLimitTier). nil = read from each
    /// account's .claude.json oauthAccount. TESTS inject so aggregate math is hermetic.
    internal var tierOverride: [String: String]?

    /// Live OAuth usage client (Anthropic `api/oauth/usage`). Persistent so its
    /// in-actor cache + 429 backoff survive between ticks. Used ONLY as a fallback
    /// for accounts whose statusline emits no `rate_limits` (e.g. a lightly-used
    /// custom account whose limits exist server-side but never reach the local
    /// statusline) — we read them straight from the source, authenticated with the
    /// account's own Keychain token.
    private let oauthClient = OAuthUsageClient(
        fetcher: URLSessionUsageFetcher(), appVersion: GroveVersion.current)

    /// Test seam: supplies OAuth limits for an account's configDir. nil = use the
    /// real client (network + Keychain). TESTS inject canned values so refresh is
    /// hermetic; returning nil for an account means "no OAuth limits available".
    public var oauthLimitsOverride: (@Sendable (_ configDir: String, _ now: Date) async -> OAuthUsage?)?

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
        // A short ease (no spring bounce) so the cross-fade settles cleanly while the
        // window resizes — simpler and more native than a sliding spring.
        withAnimation(.easeInOut(duration: 0.16)) {
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
        // Drop all per-project code-stats state and delete its history file so a
        // re-added project at the same path starts clean (the UUID differs anyway).
        // Clear any stats-branch overrides for this project's repos before dropping
        // repoStats (the only place that maps the project → its repo paths).
        for repo in repoStats[id] ?? [] {
            selectedStatsBranchByRepo.removeValue(forKey: repo.repoPath)
        }
        codeStats.removeValue(forKey: id)
        codeStatsHistory.removeValue(forKey: id)
        repoStats.removeValue(forKey: id)
        gitStatsCacheByProject.removeValue(forKey: id)
        statsStore.delete(projectID: id)
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
    /// take effect on the next scan/creation without restarting. Reuses the
    /// persistent `claude` so its transcript parse-cache survives across scans.
    public var workspaceService: WorkspaceService {
        WorkspaceService(git: GitService(), claude: claude, cmux: cmux(), config: config)
    }

    /// Scans the selected project; no-op when nothing is selected. scan() itself
    /// never throws (per-repo/cmux failures degrade into snapshot.errors).
    ///
    /// Usage refresh (account-wide, independent of selection) runs CONCURRENTLY
    /// with the scan via `async let`, and its heavy file I/O happens off the main
    /// actor (see refreshUsage), so neither freezes the panel (item 2). Both are
    /// awaited before returning so tests and the 15s loop stay deterministic.
    public func refresh() async {
        let started = Date()
        async let usage: Void = refreshUsage(now: started)
        async let sessions: Void = refreshSessionIndex()
        // Scan the selected project every tick (its detail view needs fresh data);
        // scan the OTHERS once, when they have no snapshot yet, so EVERY project card
        // shows its "N repos · M ws" count — not only the one that's been opened.
        if !config.projects.isEmpty {
            isScanning = true
            for project in config.projects
            where project.id == selectedProjectID || snapshots[project.id] == nil {
                snapshots[project.id] = await workspaceService.scan(project: project)
            }
            isScanning = false
            GroveLog.perf.info("scan \(self.config.projects.count, privacy: .public) projects: \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }
        await usage
        await sessions
    }

    /// Cheap per-project recent-session previews for the Projects tab (item 4).
    /// Independent of the heavy git scan: it only reads recent transcripts + live
    /// processes + the cmux hook map, all OFF the main actor. This is what makes
    /// the primary flow (open → pick a session → go to its terminal) instant.
    public func refreshSessionIndex() async {
        let accounts = config.accounts
        let claude = self.claude
        let cmuxMap = cmux().claudeSessionWorkspaceMap(hookFile: cmuxHookFile)
        let jobs: [(id: UUID, roots: [String])] = config.projects.map { p in
            let wsRoot = expandTilde(p.workspacesRoot
                ?? config.workspacesRootTemplate.replacingOccurrences(of: "{project}", with: p.name))
            return (id: p.id, roots: [expandTilde(p.path), wsRoot].filter { !$0.isEmpty })
        }
        let result = await Task.detached(priority: .utility) { () -> [UUID: [ProjectSessionRow]] in
            // Single source of truth (file records ∪ process table) — same data the
            // project scan / Claude tab use, so no tab can disagree on liveness.
            let live = claude.allLiveProcesses(accounts: accounts)
            var out: [UUID: [ProjectSessionRow]] = [:]
            for job in jobs {
                let sessions = claude.recentSessions(underRoots: job.roots, accounts: accounts, limit: 2)
                out[job.id] = buildProjectSessionRows(sessions: sessions, live: live, cmuxMap: cmuxMap)
            }
            return out
        }.value
        recentSessionsByProject = result
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
        expandedCommit = nil
        expandedCommitFiles = nil
    }

    /// Toggles the inline file-change list for commit `sha`. Loads the files lazily
    /// (`git show --numstat`) on first expand; a second tap collapses it.
    public func expandCommit(_ sha: String) async {
        if expandedCommit == sha { expandedCommit = nil; expandedCommitFiles = nil; return }
        guard let repoPath = graphRepoPath else { return }
        expandedCommit = sha
        expandedCommitFiles = nil   // spinner until loaded
        let files = try? await GitService().fileChanges(repoPath: repoPath, sha: sha)
        // Ignore a stale result if the user expanded a different commit meanwhile.
        if expandedCommit == sha { expandedCommitFiles = files ?? [] }
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

    /// Projects-tab session block tap (item 4): Go to the live cmux workspace
    /// hosting the session if known, else Resume it under its account in a fresh
    /// workspace. The fast routing path — no snapshot lookup needed.
    public func openSession(_ row: ProjectSessionRow) async {
        let account = config.accounts.first { $0.name == row.accountName }
            ?? config.accounts.first
            ?? AccountConfig(name: "default", configDir: "~/.claude")
        // CLOSED → open the launch sheet (target / account / model / effort) so the
        // user confirms HOW to resume before a new process is spawned.
        guard row.status != .closed else {
            beginResume(row)
            return
        }
        // LIVE → redirect to the running process; NEVER spawn a duplicate. Try each
        // gate in turn and only fall through on FAILURE — a stale/closed workspace
        // from one path must not dead-end before the others are tried.
        let service = cmux()
        // 1) cmux by workspace id (row, or re-resolved from the hook registry).
        if let target = row.cmuxWorkspaceId
            ?? service.claudeSessionWorkspaceMap(hookFile: cmuxHookFile)[row.sessionId],
           (try? await service.selectWorkspace(target)) != nil {
            return
        }
        // 2) cmux by the session's directory (the registry only tracks the ACTIVE
        //    session per workspace, so most sessions aren't in it).
        if let ws = await service.workspaceForCwd(row.cwd),
           (try? await service.selectWorkspace(ws.id)) != nil {
            return
        }
        // 3) Apple's Terminal.app, by matching the process's controlling tty.
        let claude = self.claude
        let sessionId = row.sessionId
        let focused = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let tty = claude.ttyForSession(sessionId) else { return false }
            return TerminalFocus.focusTerminalApp(tty: tty)
        }.value
        if !focused {
            actionError = "“\(row.location)” is running, but in a terminal Grove can't focus "
                + "(not cmux or Terminal.app). Switch to it in your terminal."
        }
    }

    /// Presents the launch sheet pre-filled to RESUME `row`'s session. The project's
    /// default model/effort seed the pickers (the user can override per launch).
    public func beginResume(_ row: ProjectSessionRow) {
        let project = config.projects.first { row.cwd.hasPrefix(expandTilde($0.path)) }
        launchRequest = LaunchRequest(
            sessionId: row.sessionId, cwd: row.cwd, title: row.location,
            account: row.accountName,
            model: project?.defaultModel, effort: project?.defaultEffort, target: .cmux)
    }

    /// Presents the launch sheet for a fresh ("New Claude") session in `cwd`
    /// under `account`. Parallels `beginResume` (`sessionId: nil`), seeding the
    /// pickers with the owning project's default model/effort so the user can
    /// confirm target/model/effort before a process is spawned.
    public func beginNew(cwd: String, title: String, account: AccountConfig) {
        let owner = project(forCwd: cwd)
        launchRequest = LaunchRequest(
            sessionId: nil, cwd: cwd, title: title,
            account: account.name,
            model: owner?.defaultModel ?? account.defaultModel,
            effort: owner?.defaultEffort ?? account.defaultEffort, target: .cmux)
    }

    /// Runs the configured launch (Resume or New) at the chosen target. Closes the
    /// sheet first so it can't be double-submitted.
    public func confirmLaunch(_ request: LaunchRequest) async {
        launchRequest = nil
        let account = config.accounts.first { $0.name == request.account }
            ?? config.accounts.first ?? AccountConfig(name: "default", configDir: "~/.claude")
        switch request.target {
        case .cmux:
            await launchClaude(cwd: request.cwd, title: request.title, account: account,
                               resume: request.sessionId, model: request.model, effort: request.effort)
        case .terminal:
            let command = ClaudeService.launchCommand(account: account, resume: request.sessionId,
                                                      model: request.model, effort: request.effort)
            let cwd = request.cwd
            let ok = await Task.detached(priority: .userInitiated) {
                TerminalFocus.launchInTerminal(command: command, cwd: cwd)
            }.value
            if !ok { actionError = "Couldn't open Terminal.app for the session." }
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
        // File records attribute an account — prefer the precise name.
        for account in config.accounts where account.name != launchAccount.name {
            if service.liveProcesses(account: account).contains(where: { $0.sessionId == sessionId }) {
                return account.name
            }
        }
        // The session may be live via the process TABLE (which the often-empty file
        // records miss, and which can't attribute an account). If it's running
        // anywhere and NOT under the launch account's own records, still refuse — a
        // second `--resume` would have two processes writing one transcript.
        let liveInTable = service.liveProcessesFromTable().contains { $0.sessionId == sessionId }
        let liveUnderLaunch = service.liveProcesses(account: launchAccount).contains { $0.sessionId == sessionId }
        if liveInTable && !liveUnderLaunch { return "a running session" }
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

    public enum LimitWindow { case fiveHour, sevenDay, sevenDaySonnet }

    /// Selects a window from a snapshot for the given `LimitWindow`.
    static func pick(_ window: LimitWindow) -> (UsageSnapshot) -> CapturedWindow? {
        switch window {
        case .fiveHour:       return { $0.fiveHour }
        case .sevenDay:       return { $0.sevenDay }
        case .sevenDaySonnet: return { $0.sevenDaySonnet }
        }
    }

    /// Reads capture snapshots + analytics across accounts (called on the scan tick).
    /// `now` injected; defaults to Date() ONLY at the production call site.
    ///
    /// The file reads + JSON parsing run OFF the main actor (`Task.detached`) so a
    /// cold transcript parse never freezes the panel on open (item 2). The shared
    /// `usageAnalytics` keeps its mtime cache between calls, so steady-state ticks
    /// only re-parse changed files. Results are assigned back on the main actor.
    public func refreshUsage(now: Date) async {
        let analytics = usageAnalytics
        let jobs: [(name: String, dir: String, claudeJSON: String)] = config.accounts.map {
            (name: $0.name, dir: expandTilde($0.configDir), claudeJSON: claudeJSONPath(for: $0))
        }
        let started = Date()
        let result = await Task.detached(priority: .utility) {
            () -> (snaps: [String: [UsageSnapshot]], byAcc: [String: AccountUsageAnalytics]) in
            let reader = UsageReader()
            var snaps: [String: [UsageSnapshot]] = [:]
            var byAcc: [String: AccountUsageAnalytics] = [:]
            for job in jobs {
                snaps[job.name] = reader.read(configDir: job.dir, accountName: job.name)
                byAcc[job.name] = analytics.account(configDir: job.dir, accountName: job.name,
                                                    claudeJSONPath: job.claudeJSON, now: now)
            }
            return (snaps, byAcc)
        }.value
        var snaps = result.snaps
        // OAuth limits from Anthropic's usage API, folded in as the latest capture
        // for EVERY account. This is the authoritative source AND the only one that
        // carries the 7-day Sonnet window (the statusline emits only five_hour /
        // seven_day). Cached ≥3min in the client, so this is at most one request
        // per account per few minutes; failures fall back to the statusline captures.
        let provider: @Sendable (String, Date) async -> OAuthUsage? =
            oauthLimitsOverride ?? { [oauthClient] dir, now in try? await oauthClient.usage(configDir: dir, now: now) }
        for job in jobs {
            guard let usage = await provider(job.dir, now),
                  let snap = Self.oauthSnapshot(accountName: job.name, usage: usage, now: now) else { continue }
            snaps[job.name, default: []].append(snap)
        }
        snapshotsByAccount = snaps
        usageByAccount = result.byAcc
        GroveLog.perf.info("usage refresh (\(jobs.count) accts): \(Int(Date().timeIntervalSince(started) * 1000))ms")
    }

    /// Builds a synthetic capture from OAuth usage so the dashboard, aggregate, and
    /// header chip pick up the limits exactly like a statusline capture. The API's
    /// `utilization` is already a 0–100 used-percentage (verified against the live
    /// endpoint: e.g. seven_day = 2.0 = 2% used) — we only clamp it. Returns nil
    /// when neither the 5h nor the 7d window is present.
    static func oauthSnapshot(accountName: String, usage: OAuthUsage, now: Date) -> UsageSnapshot? {
        func window(_ w: OAuthWindow?) -> CapturedWindow? {
            guard let w else { return nil }
            return CapturedWindow(usedPercentage: min(max(w.utilization, 0), 100), resetsAt: w.resetsAt)
        }
        let five = window(usage.fiveHour)
        let seven = window(usage.sevenDay)
        let sonnet = window(usage.sevenDaySonnet)
        guard five != nil || seven != nil || sonnet != nil else { return nil }
        return UsageSnapshot(accountName: accountName, sessionId: "oauth", capturedAt: now, cwd: nil,
                             modelId: nil, modelDisplayName: nil, effort: nil,
                             contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                             fiveHour: five, sevenDay: seven, sevenDaySonnet: sonnet)
    }

    private func tier(for account: AccountConfig) -> String? {
        if let t = tierOverride?[account.name] { return t }
        // Production: the weight table keys on organizationRateLimitTier (e.g.
        // "default_claude_max_20x"), NOT identity().tier (which is the often-nil
        // userRateLimitTier). Read the canonical field directly.
        return ClaudeService().organizationRateLimitTier(account: account)
    }

    private func claudeJSONPath(for account: AccountConfig) -> String {
        let dir = expandTilde(account.configDir)
        return dir == NSHomeDirectory() + "/.claude"
            ? NSHomeDirectory() + "/.claude.json" : dir + "/.claude.json"
    }

    /// Aggregate remaining capacity for a window across accounts (spec §C.3): each
    /// account weighted by tier, combined with its most-recent capture's used%.
    public func aggregateRemaining(window: LimitWindow, now: Date) -> RateLimitModel.Aggregate {
        let accounts: [RateLimitModel.AccountWindow] = config.accounts.compactMap { account in
            let snaps = snapshotsByAccount[account.name] ?? []
            // Per-window resolution: statusline first, OAuth-fetched limits as the
            // fallback (FIX I2). An account whose statusline lacks rate_limits but
            // whose limits come from the OAuth usage API still contributes here, so
            // the "Overall" scope consolidates EVERY account, not just the ones with
            // statusline windows. Only a window absent from BOTH sources drops out.
            let captured = accountWindow(snaps, Self.pick(window), now: now)
            guard let used = captured?.usedPercentage else { return nil }
            return RateLimitModel.AccountWindow(tier: tier(for: account), usedPercentage: used)
        }
        return RateLimitModel.aggregateRemaining(accounts)
    }

    /// Summing principle for windows that reset at DIFFERENT times: the remaining
    /// capacity is the tier-weighted sum above (how much headroom you have RIGHT
    /// NOW across accounts); the reset shown is the SOONEST upcoming one — the next
    /// moment any account's window refreshes and headroom returns. Returns that
    /// instant, or nil when no account has a future reset on record.
    public func aggregateReset(window: LimitWindow, now: Date) -> Date? {
        let windows: [CapturedWindow] = config.accounts.compactMap { account in
            let snaps = snapshotsByAccount[account.name] ?? []
            // Same statusline-first, OAuth-fallback resolution as aggregateRemaining
            // (FIX I2) so the soonest reset spans EVERY account's windows.
            return accountWindow(snaps, Self.pick(window), now: now)
        }
        return soonestReset(windows, now: now).flatMap(parseISODate)
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

// MARK: - Code stats

extension AppState {
    /// The directory holding per-project code-stats history files. Production:
    /// ~/Library/Application Support/Grove/stats; tests inject statsStoreDirOverride.
    private var statsStoreDir: URL {
        if let override = statsStoreDirOverride { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grove/stats")
    }

    /// Built fresh from the resolved dir (a value type that just holds the URL). The
    /// scanner + cache that must persist across ticks live on `self`, not here.
    private var statsStore: CodeStatsStore { CodeStatsStore(dir: statsStoreDir) }

    /// Scans the project's code per-GIT-REPO (GitStatsService), updates the aggregate
    /// `codeStats`, the per-repo `repoStats` breakdown, and overwrites
    /// `codeStatsHistory` with the git-derived per-day series. Built like refreshUsage:
    /// the project's path, scan depth, excluded repos, and that project's git-stats
    /// cache are captured OFF the main actor in a `.utility` Task.detached; the git
    /// subprocesses + file reads happen there so they never freeze the panel. Results
    /// (and the updated cache) are assigned back on the main actor.
    /// No-op for an unknown id. `isStatsScanning` brackets the whole operation.
    public func refreshCodeStats(projectID: UUID, now: Date = Date()) async {
        // Serialize per project: if a scan for this project is already running, record
        // that another is wanted and return — the in-flight scan re-runs once when it
        // finishes (see the tail below). This prevents two scans racing on the shared
        // mtime cache, while still honoring a refresh requested mid-scan (e.g. after a
        // folder-exclusion toggle clears the cache).
        guard !statsScanInFlight.contains(projectID) else {
            statsRescanPending.insert(projectID)
            return
        }
        await runCodeStatsScan(projectID: projectID, now: now)
    }

    private func runCodeStatsScan(projectID: UUID, now: Date) async {
        guard let project = config.projects.first(where: { $0.id == projectID }) else { return }
        let path = project.path
        let depth = project.scanDepth
        let excluded = Set(project.excludedRepos)
        let excludedFolders = Set(project.statsIgnoredFolders)
        let cache = gitStatsCacheByProject[projectID] ?? [:]
        let service = gitStats
        let branchOverrides = selectedStatsBranchByRepo

        statsScanInFlight.insert(projectID)
        statsRescanPending.remove(projectID)
        isStatsScanning = true
        let result = await Task.detached(priority: .utility) {
            () -> (stats: ProjectGitStats, cache: [String: RepoFileCache]) in
            var local = cache
            let stats = await service.scan(projectPath: path, scanDepth: depth,
                                           excludedRepos: excluded, excludedFolders: excludedFolders,
                                           branchOverrides: branchOverrides,
                                           now: now, cache: &local)
            return (stats, local)
        }.value
        statsScanInFlight.remove(projectID)
        isStatsScanning = !statsScanInFlight.isEmpty
        // A concurrent removeProject (or another refresh) may have run while detached;
        // only commit if the project still exists.
        guard config.projects.contains(where: { $0.id == projectID }) else {
            statsRescanPending.remove(projectID)
            return
        }
        // Aggregate feeds the existing screen; the per-repo breakdown is new.
        codeStats[projectID] = result.stats.aggregate
        repoStats[projectID] = result.stats.repos
        statsFiles[projectID] = result.stats.files
        gitStatsCacheByProject[projectID] = result.cache

        // History now comes from GIT and is authoritative — OVERWRITE the stored series
        // each scan (not append/coalesce). The store stays as the cross-launch cache;
        // the screen reads `codeStatsHistory[id]` unchanged.
        let history = CodeStatsHistory(points: result.stats.aggregateHistory)
        try? statsStore.save(projectID: projectID, history: history)
        codeStatsHistory[projectID] = result.stats.aggregateHistory

        // Populate the branch-switcher menus: the scan already discovered every repo,
        // so reuse its [RepoStats] to load each repo's local branches into
        // branchesByRepo (the same source the Graph's branch pickers use).
        let reposForBranches = result.stats.repos.map {
            RepoInfo(path: $0.repoPath, dirName: $0.repoName)
        }
        await loadBranches(for: reposForBranches)

        // Honor a refresh that arrived while this scan was running (its cache may now
        // be stale — e.g. a repo-exclusion toggle), serialized strictly after us.
        if statsRescanPending.remove(projectID) != nil {
            await runCodeStatsScan(projectID: projectID, now: Date())
        }
    }

    /// Stats-tab branch switcher: record the chosen branch for `repoPath` and rescan
    /// the project so its history/delta reflect the new branch (current LOC is taken
    /// from the working tree and is branch-independent, so it stays put). Honors the
    /// per-project scan serialization via refreshCodeStats.
    public func setStatsBranch(projectID: UUID, repoPath: String, branch: String) {
        selectedStatsBranchByRepo[repoPath] = branch
        Task { await refreshCodeStats(projectID: projectID) }
    }

    /// Excludes (or re-includes) a project-root-relative folder from code-stats
    /// scans: mutates `ProjectConfig.statsIgnoredFolders`, persists, and clears that
    /// project's stats cache so the next refresh re-tallies without the stale
    /// contributions of a folder whose exclusion just changed. No-op for an unknown
    /// id, or when the requested state already holds.
    public func setStatsFolderExcluded(projectID: UUID, relativePath: String, excluded: Bool) {
        guard let i = config.projects.firstIndex(where: { $0.id == projectID }) else { return }
        var folders = config.projects[i].statsIgnoredFolders
        let alreadyExcluded = folders.contains(relativePath)
        if excluded {
            guard !alreadyExcluded else { return }
            folders.append(relativePath)
        } else {
            guard alreadyExcluded else { return }
            folders.removeAll { $0 == relativePath }
        }
        config.projects[i].statsIgnoredFolders = folders
        gitStatsCacheByProject[projectID] = [:]
        persist()
        // Trigger an immediate rescan so the toggle actually changes the numbers + the
        // file tree. `refreshCodeStats` serializes per project (queues a clean rescan if
        // one is already in flight), so rapid toggling never races on the shared cache.
        Task { await refreshCodeStats(projectID: projectID) }
    }

    /// I/O-light directory skeleton for the exclusion picker (off the main actor —
    /// it walks dirs but reads no files).
    public func statsDirectoryTree(projectID: UUID) async -> DirNode? {
        guard let project = config.projects.first(where: { $0.id == projectID }) else { return nil }
        let path = project.path
        let scanner = statsScanner
        return await Task.detached(priority: .utility) { scanner.directoryTree(projectPath: path) }.value
    }
}
