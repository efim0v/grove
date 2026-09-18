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
    /// When the displayed limits were actually OBTAINED — the newest `capturedAt`
    /// across every account's captures, not the time the refresh loop last ran. The
    /// OAuth client caches for 180s, so a tick can pass without the numbers moving;
    /// the panel's footer must not claim such data is current. nil until first data.
    @Published public var usageDataAsOf: Date?
    /// True while a usage FETCH is in flight — the footer swaps its refresh button for
    /// a loading indicator. Only set by passes that actually go to the network, never
    /// by the local liveness tick.
    @Published public var isRefreshingUsage: Bool = false
    /// Why the last usage FETCH failed, or nil when it succeeded. The OAuth call used to
    /// be a bare `try?`: an expired bearer, a 429 backoff or a dead network produced a
    /// silent no-op, the panel kept showing its retained capture, and pressing Refresh
    /// looked like a broken button. Cleared on the next success. Only fetch passes touch
    /// it — a local liveness tick makes no request and so can neither set nor clear it.
    @Published public var usageFetchError: String?
    /// Newest successful synthetic OAuth capture per account. Nothing persists these
    /// (only the statusline writes `grove/usage`), and `refreshUsage` rebuilds
    /// `snapshotsByAccount` from disk every pass — so this is what keeps the
    /// API-only windows on screen between fetches. See the re-attach step in
    /// `refreshUsage` for why dropping them made the model bar blink.
    private var lastOAuthSnapshot: [String: UsageSnapshot] = [:]
    /// Per-account snapshot-delta cost ledger — the forward-accurate daily-cost source for the
    /// Daily Usage chart, accumulated from statusline snapshots in refreshUsage and persisted.
    @Published public var usageLedgerByAccount: [String: UsageCostLedger] = [:]
    /// Monotonic per-account save generation (bumped on each ledger change on the main actor) +
    /// the serial writer that uses it to drop out-of-order stale persists.
    private var ledgerGeneration: [String: Int] = [:]
    private let ledgerWriter = UsageLedgerWriter()
    /// Per-account `organizationRateLimitTier`, resolved OFF the main actor in
    /// refreshUsage. aggregateRemaining (and thus several view bodies, incl. the
    /// always-visible charts pane) reads this via tier(for:) — it must never hit disk.
    var tierCache: [String: String] = [:]
    /// Per-account identity (email/org/tier), resolved OFF the main actor in
    /// refreshUsage. AccountsScreen reads this instead of a synchronous .claude.json
    /// read per card per render. Empty until the first refresh (the screen falls back
    /// to its injected provider then — which is also the snapshot seam).
    var identityByAccount: [String: AccountIdentity] = [:]
    /// Per-project recent Claude sessions (item 4): the Projects tab's previews.
    /// Filled by refreshSessionIndex (cheap, off-main — no git scan).
    @Published public var recentSessionsByProject: [UUID: [ProjectSessionRow]] = [:]
    /// Disk-wide recent sessions (Phase 2 / Task 2) attributed to a configured
    /// project by cwd prefix match. Keyed by ProjectConfig.id, newest-first.
    /// Populated by refreshSessionIndex alongside recentSessionsByProject.
    @Published public var externalSessionsByProject: [UUID: [ClaudeSession]] = [:]
    /// Disk-wide recent sessions whose cwd matches NO configured project.
    /// Newest-first. Populated by refreshSessionIndex.
    @Published public var otherSessions: [ClaudeSession] = []
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
    /// In-flight debounce task for `setStatsBranch` — cancelled and rescheduled on each
    /// rapid branch pick so N quick switches coalesce to one rescan.
    private var statsBranchDebounce: Task<Void, Never>?

    /// Debounce interval (seconds) for branch-switch rescans. Default 0.25s in production;
    /// tests set this to 0 so the debounce fires synchronously and the coalesce assertion
    /// is deterministic without artificial sleeps.
    internal var statsBranchDebounceInterval: TimeInterval = 0.25

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

    /// Test seam: injects a fixed live-process list into adoptSession's liveness
    /// guard, bypassing both file-record reads AND the process-table scan. Required
    /// for testing the table-only live path (cwd=="", sessionId set) without a real
    /// process. nil means the real allLiveProcesses call.
    internal var allLiveProcessesOverride: [LiveProcess]?

    /// Test seam: the app-support dir the statusline wrapper script is shipped
    /// into. nil = the real ~/Library/Application Support/Grove/bin. TESTS set a
    /// temp dir so install never writes under the real app-support tree.
    internal var statuslineScriptDirOverride: String?

    /// Test seam: the base dir under which NEW accounts' config dirs are created by
    /// `addAccount` (which also auto-installs a statusline there). nil = the real
    /// ~/.claude-accounts. TESTS set a temp dir so addAccount never creates a real
    /// account dir / writes a real settings.json under $HOME.
    internal var accountsRootOverride: String?

    /// Test seam: the directory the per-project code-stats history files live in.
    /// nil = the real ~/Library/Application Support/Grove/stats. TESTS set a temp
    /// dir so history persistence never writes under the real app-support tree.
    internal var statsStoreDirOverride: String?

    /// Test seam: the directory the per-account usage-cost ledger files live in. nil = the real
    /// ~/Library/Application Support/Grove/usageledger. TESTS that call refreshUsage MUST set a
    /// temp dir so the ledger never writes under the real app-support tree.
    internal var usageLedgerStoreDirOverride: String?

    /// Test seam: account tiers (organizationRateLimitTier). nil = read from each
    /// account's .claude.json oauthAccount. TESTS inject so aggregate math is hermetic.
    internal var tierOverride: [String: String]?

    /// Test observability: incremented each time `runCodeStatsScan` begins a scan. nil
    /// in production (never read); tests set it to 0 before calling `setStatsBranch`
    /// and assert it equals 1 after the debounce fires to verify coalescing.
    internal var statsRescanStartedCount: Int?

    /// Live OAuth usage client (Anthropic `api/oauth/usage`). Persistent so its
    /// in-actor cache + 429 backoff survive between ticks. Used ONLY as a fallback
    /// for accounts whose statusline emits no `rate_limits` (e.g. a lightly-used
    /// custom account whose limits exist server-side but never reach the local
    /// statusline) — we read them straight from the source, authenticated with the
    /// account's own Keychain token.
    private let oauthClient = OAuthUsageClient(
        fetcher: URLSessionUsageFetcher(), appVersion: GroveVersion.current,
        // One bucket picture shared with Brow (the notch utility): see UsagePacingLedger.
        ledger: FileUsagePacingLedger(),
        // Cache the Keychain token per launch so reading Claude Code's credentials
        // prompts the user at most once per account per launch (not every ~3-min poll).
        credentials: CachingCredentialsReader())

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
        // INSTANT route change — no withAnimation. Animating the route swap made
        // Apple's Liquid Glass framework (DesignLibrary / MaterialProviderBox) recurse
        // to a stack-overflow SIGSEGV while it re-resolved the glass layers of the
        // animated SwiftUI content INSIDE the window's NSGlassEffectView (introduced by
        // the one-window merge). A non-animated swap renders once and never re-enters
        // that resolution mid-interpolation.
        route = target
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

    /// Transcript safety-net settings edit (GlobalSettingsScreen); persists immediately.
    public func setTranscriptMirror(_ settings: TranscriptMirrorSettings) {
        config.transcriptMirror = settings
        persist()
    }

    /// New account convention (spec §6.3): configDir = ~/.claude-accounts/<name>
    /// (redirectable in tests via `accountsRootOverride`). Phase 5A: also creates the
    /// dir and auto-installs the grove statusline there so the account captures usage
    /// from its first session (best-effort — account creation still succeeds if the
    /// install fails).
    public func addAccount(name: String) {
        guard !config.accounts.contains(where: { $0.name == name }) else {
            actionError = "account '\(name)' already exists"
            return
        }
        let configDir = accountsRootOverride.map { $0 + "/" + name } ?? "~/.claude-accounts/\(name)"
        let account = AccountConfig(name: name, configDir: configDir)
        config.accounts.append(account)
        persist()
        enableMonitoring(account, reportErrors: false)
    }

    /// Removes the account from Grove's config only — the directory is untouched.
    public func removeAccount(name: String) {
        config.accounts.removeAll { $0.name == name }
        usageLedgerByAccount.removeValue(forKey: name)
        usageLedgerStore.delete(account: name)
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
    /// `oauth` defaults to `.skip` because this is the 15s liveness tick: it re-reads
    /// local captures, sessions and worktrees, and must not touch the rate-limited
    /// usage API. The panel-open pass passes `.fetch` once.
    public func refresh(oauth policy: OAuthPolicy = .skip) async {
        let started = Date()
        async let usage: Void = refreshUsage(now: started, oauth: policy)
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
        await reconcileTranscripts()
    }

    /// Cheap per-project recent-session previews for the Projects tab (item 4).
    /// Independent of the heavy git scan: it only reads recent transcripts + live
    /// processes + the cmux hook map, all OFF the main actor. This is what makes
    /// the primary flow (open → pick a session → go to its terminal) instant.
    ///
    /// Also populates `externalSessionsByProject` and `otherSessions` (Phase 2 /
    /// Task 2): a disk-wide scan of ALL recent sessions attributed to projects by
    /// cwd prefix. The recency cap reuses `config.transcriptMirror.maxDays` (90 by
    /// default). allRecentSessions + attribution both run inside the detached task;
    /// the finished dictionaries are assigned back on the main actor.
    public func refreshSessionIndex() async {
        let accounts = config.accounts
        let claude = self.claude
        let cmuxMap = cmux().claudeSessionWorkspaceMap(hookFile: cmuxHookFile)
        let jobs: [(id: UUID, roots: [String])] = config.projects.map { p in
            let wsRoot = expandTilde(p.workspacesRoot
                ?? config.workspacesRootTemplate.replacingOccurrences(of: "{project}", with: p.name))
            return (id: p.id, roots: [expandTilde(p.path), wsRoot].filter { !$0.isEmpty })
        }
        let sinceDays = config.transcriptMirror.maxDays
        let now = Date()

        // Precompute canonical roots for every project ONCE on the main actor
        // (reads config.projects; each root is a single resolvingSymlinksInPath syscall).
        // The per-session attribution loop below needs these but runs off-main — we
        // pass a value snapshot so the closure never touches main-actor state. (I1 fix)
        let projectRoots: [(id: UUID, roots: [String])] = config.projects.map { p in
            let roots = [expandTilde(p.path), expandTilde(p.workspacesRoot ?? "")]
                .filter { !$0.isEmpty }
                .map { canonicalPath($0) }
            return (id: p.id, roots: roots)
        }

        let (sessionRows, byProject, unmatched) = await Task.detached(priority: .utility) {
            () -> ([UUID: [ProjectSessionRow]], [UUID: [ClaudeSession]], [ClaudeSession]) in
            // Single source of truth (file records ∪ process table) — same data the
            // project scan / Claude tab use, so no tab can disagree on liveness.
            let live = claude.allLiveProcesses(accounts: accounts)
            var out: [UUID: [ProjectSessionRow]] = [:]
            for job in jobs {
                let sessions = claude.recentSessions(underRoots: job.roots, accounts: accounts, limit: 2)
                out[job.id] = buildProjectSessionRows(sessions: sessions, live: live, cmuxMap: cmuxMap)
            }
            // Disk-wide scan for attribution indices (Phase 2 / Task 2).
            // 500 is a GLOBAL budget across all projects (newest-first over the
            // ~90d transcriptMirror.maxDays window), so on a very active machine a
            // rarely-used project's recent sessions can fall below the cut.
            let all = claude.allRecentSessions(accounts: accounts, limit: 500,
                                               sinceDays: sinceDays, now: now)

            // Attribute sessions to projects off the main actor using the precomputed
            // canonical roots snapshot — avoids resolvingSymlinksInPath syscalls (up to
            // 500 sessions × N projects) on the main thread. (I1 fix)
            var sessionsByProject: [UUID: [ClaudeSession]] = [:]
            var otherSessions: [ClaudeSession] = []
            for session in all {
                let sessionCanon = canonicalPath(session.cwd)
                if let match = projectRoots.first(where: { proj in
                    proj.roots.contains { sessionCanon == $0 || sessionCanon.hasPrefix($0 + "/") }
                }) {
                    sessionsByProject[match.id, default: []].append(session)
                } else {
                    otherSessions.append(session)
                }
            }
            return (out, sessionsByProject, otherSessions)
        }.value
        recentSessionsByProject = sessionRows
        externalSessionsByProject = byProject
        otherSessions = unmatched
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
                             model: String? = nil, effort: String? = nil,
                             skipPermissions: Bool? = nil) async {
        let service = cmux()
        // --dangerously-skip-permissions: an explicit per-launch choice (from the
        // config sheet) wins; otherwise resolve the project default by `cwd`, here in
        // the single launch chokepoint so EVERY caller honors the setting.
        let command = ClaudeService.launchCommand(account: account, resume: sessionId,
                                                  model: model, effort: effort,
                                                  skipPermissions: skipPermissions ?? effectiveSkipPermissions(cwd: cwd))
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
    public func setProjectSkipPermissions(projectID: UUID, _ on: Bool) {
        guard let i = config.projects.firstIndex(where: { $0.id == projectID }) else { return }
        config.projects[i].dangerouslySkipPermissions = on
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

    /// Whether to launch with `--dangerously-skip-permissions` for `cwd`: the owning
    /// project's per-project toggle (false when no project owns the cwd, e.g. a login
    /// shell at $HOME). Project-scoped only — there is no account/global form.
    func effectiveSkipPermissions(cwd: String) -> Bool {
        project(forCwd: cwd)?.dangerouslySkipPermissions ?? false
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

    /// Seeds the launch/config sheet for `cwd`/`sessionId` with the owning project's
    /// defaults (model / effort / skip-permissions), letting the user override any
    /// of them — plus the account and target — before the launch runs. `account` is
    /// recorded as BOTH the chosen and the origin account, so a later account change
    /// in the sheet is detected as a cross-account resume.
    private func seedLaunch(sessionId: String?, cwd: String, title: String, account: String) {
        let owner = project(forCwd: cwd)
        let acct = config.accounts.first { $0.name == account }
        launchRequest = LaunchRequest(
            sessionId: sessionId, cwd: cwd, title: title,
            account: account, originAccount: account,
            model: owner?.defaultModel ?? acct?.defaultModel,
            effort: owner?.defaultEffort ?? acct?.defaultEffort,
            skipPermissions: effectiveSkipPermissions(cwd: cwd),
            target: .cmux)
    }

    /// Presents the launch sheet pre-filled to RESUME `row`'s session.
    public func beginResume(_ row: ProjectSessionRow) {
        seedLaunch(sessionId: row.sessionId, cwd: row.cwd, title: row.location, account: row.accountName)
    }

    /// Presents the launch sheet for a fresh ("New Claude") session in `cwd`.
    public func beginNew(cwd: String, title: String, account: AccountConfig) {
        seedLaunch(sessionId: nil, cwd: cwd, title: title, account: account.name)
    }

    /// Opens the per-session config/relaunch sheet for a Claude-tab row (closed →
    /// resume with new model / effort / account / skip-permissions).
    public func beginConfigure(_ row: SessionRow) {
        seedLaunch(sessionId: row.sessionId, cwd: row.cwd, title: row.title, account: row.accountName)
    }

    /// Opens the per-session config/relaunch sheet for a Workspaces-tab session.
    public func beginConfigure(session: ClaudeSession) {
        let title = session.title ?? (session.cwd as NSString).lastPathComponent
        seedLaunch(sessionId: session.id, cwd: session.cwd, title: title, account: session.accountName)
    }

    /// Runs the configured launch (Resume or New) at the chosen target. Closes the
    /// sheet first so it can't be double-submitted.
    public func confirmLaunch(_ request: LaunchRequest) async {
        launchRequest = nil
        let account = config.accounts.first { $0.name == request.account }
            ?? config.accounts.first ?? AccountConfig(name: "default", configDir: "~/.claude")
        // Resuming under a DIFFERENT account than the session belongs to needs the
        // canonical-store linking first (so the new account's claude sees the
        // transcript); abort the launch if that move is blocked.
        if let sessionId = request.sessionId, !sessionId.isEmpty {
            guard prepareResumeAccount(sessionId: sessionId, cwd: request.cwd,
                                       fromAccount: request.originAccount, to: account) else { return }
        }
        switch request.target {
        case .cmux:
            await launchClaude(cwd: request.cwd, title: request.title, account: account,
                               resume: request.sessionId, model: request.model, effort: request.effort,
                               skipPermissions: request.skipPermissions)
        case .terminal:
            let command = ClaudeService.launchCommand(account: account, resume: request.sessionId,
                                                      model: request.model, effort: request.effort,
                                                      skipPermissions: request.skipPermissions)
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
    /// test override). Linking roots here; it is never symlinked. Internal so
    /// views in the same module (SessionsScreen, OtherSessionsScreen) can evaluate
    /// canShareAcrossAccounts without recomputing the path.
    var canonicalDir: String {
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
        // Phase 5A: capture usage by default for every linked account.
        enableMonitoring(account, reportErrors: false)
    }

    // MARK: - Transcript mirror

    /// Hardlink-mirror + auto-restore every account's transcripts, off the main
    /// actor. No-ops when the feature is disabled or when no canonical account is
    /// configured. Snapshot-render safety comes from the caller not invoking this
    /// during `ImageRenderer` passes — the same structural guarantee `verifySharedStore`
    /// relies on.
    public func reconcileTranscripts() async {
        guard config.transcriptMirror.enabled, canonicalAccount != nil else { return }
        let canonical = canonicalDir
        let accts = config.accounts.map {
            MirrorAccount(key: accountKey($0.configDir), configDir: expandTilde($0.configDir))
        }
        let policy = RetentionPolicy(
            maxDays: config.transcriptMirror.maxDays,
            maxBytes: Int64(config.transcriptMirror.maxMB) * 1_000_000)
        let report = await Task.detached(priority: .utility) {
            TranscriptMirror().reconcile(accounts: accts, canonicalDir: canonical, policy: policy)
        }.value
        if let first = report.issues.first { actionError = "Transcript mirror: \(first)" }
    }

    // MARK: - Session migration (Phase 4A4)

    /// Full cross-account session migration: copies the session's transcript,
    /// aux files, tasks, settings keys, and plugins into the target account's
    /// configDir — non-destructively (never overwrites). No-op when source and
    /// target share the same account name.
    public func migrateSession(cwd: String, sessionId: String,
                               from sourceAccount: AccountConfig,
                               to targetAccount: AccountConfig) async {
        guard sourceAccount.name != targetAccount.name else { return }

        let fromConfigDir = expandTilde(sourceAccount.configDir)
        let toConfigDir   = expandTilde(targetAccount.configDir)

        // SAFETY: refuse if any process is live under the TARGET account.
        // migratePlugins and migrateSettings do atomic read-modify-write of the target's
        // hot config files; a concurrent claude process writing those files between our
        // read and write causes a silent lost update.
        let live: [LiveProcess]
        if let override = allLiveProcessesOverride {
            live = override
        } else {
            let service = liveProcessValidatorOverride
                .map { ClaudeService().withProcessValidator($0) } ?? ClaudeService()
            live = service.allLiveProcesses(accounts: config.accounts)
        }
        if live.contains(where: { $0.accountName == targetAccount.name }) {
            actionError = "Target account \"\(targetAccount.name)\" has a running session — close it before migrating (its config could be overwritten)."
            return
        }
        let fromHomeJSON  = claudeJSONPath(for: sourceAccount)
        let toHomeJSON    = claudeJSONPath(for: targetAccount)
        let mirrorRoot    = TranscriptMirror.mirrorRoot(canonicalDir: canonicalDir)
        let fromKey       = accountKey(fromConfigDir)

        // Ensure the target's standard directories exist (like linkAccount does).
        let fm = FileManager.default
        try? fm.createDirectory(atPath: toConfigDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: toConfigDir + "/projects", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: toConfigDir + "/plugins", withIntermediateDirectories: true)

        let report = await Task.detached(priority: .utility) {
            SessionMigration.migrateSession(
                sessionId: sessionId, cwd: cwd,
                fromConfigDir: fromConfigDir, toConfigDir: toConfigDir,
                fromHomeJSON: fromHomeJSON, toHomeJSON: toHomeJSON,
                mirrorRoot: mirrorRoot, fromAccountKey: fromKey)
        }.value

        if let first = report.issues.first { actionError = "Migrate: \(first)" }
        // Phase 5A: capture usage by default for the target account now that it holds
        // a real session. Use the persisted entry so the gate reflects prior state.
        if let target = config.accounts.first(where: { $0.name == targetAccount.name }),
           !target.monitoring {
            enableMonitoring(target, reportErrors: false)
        }
        await refreshSessionIndex()
    }

    /// Permanent delete of a session's transcript (mirror + live sides), then
    /// refreshes the session index. Failures land in actionError.
    public func purgeTranscript(id: String) {
        guard canonicalAccount != nil else { return }
        let accts = config.accounts.map {
            MirrorAccount(key: accountKey($0.configDir), configDir: expandTilde($0.configDir))
        }
        do {
            try TranscriptMirror().purge(sessionId: id, accounts: accts, canonicalDir: canonicalDir)
        } catch {
            actionError = "Couldn't purge transcript: \(error.localizedDescription)"
        }
        Task { await refreshSessionIndex() }
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

    // MARK: - Session adoption (Phase 2 / Task 4)

    /// Predicate: true when `account` is NOT the canonical/default account, meaning
    /// its sessions are not yet shared and can benefit from adoption. Pure, static,
    /// unit-testable. `canonicalDir` is the expanded canonical store path.
    public static func canShareAcrossAccounts(account: AccountConfig, canonicalDir: String) -> Bool {
        expandTilde(account.configDir) != canonicalDir
    }

    /// Brings a session discovered under `account` into the canonical shared store so
    /// its transcript is reachable from every linked account.
    ///
    /// Safety contract:
    /// - No-op when `account` IS the canonical account (already shared).
    /// - Aborts with `actionError` when the session is currently live under ANY account
    ///   (ensureWorkspaceLinked moves the transcript file; moving an open file causes
    ///   data loss for the running process).
    /// - On success, refreshes the session index so the UI reflects the new state.
    ///
    /// `sessionId` is required to catch sessions that are live via
    /// `claude --resume <id>` / `--session-id <id>` — these appear in the process
    /// table with `cwd == ""`, so cwd-only matching misses them (C1 fix).
    public func adoptSession(cwd: String, sessionId: String, account: AccountConfig) async {
        // No-op for the canonical/default account — already the root of sharing.
        guard Self.canShareAcrossAccounts(account: account, canonicalDir: canonicalDir) else { return }

        // SAFETY: refuse if the session is live anywhere. ensureWorkspaceLinked moves
        // the transcript file; an open file descriptor on the moved file means future
        // writes from the live claude process go to an unlinked inode (data loss).
        // ClaudeService.isSessionLive checks BOTH sessionId (table-only --resume path,
        // cwd=="") AND cwd (fresh sessions) so neither liveness signal is missed.
        let live: [LiveProcess]
        if let override = allLiveProcessesOverride {
            live = override
        } else {
            let service = liveProcessValidatorOverride
                .map { ClaudeService().withProcessValidator($0) } ?? ClaudeService()
            live = service.allLiveProcesses(accounts: config.accounts)
        }
        let mangled = ClaudeService.mangle(cwd)
        if ClaudeService.isSessionLive(among: live, cwd: cwd, sessionId: sessionId) {
            actionError = "This session is running — close it, then Share."
            return
        }

        if let error = ensureLinkedForResume(account, mangledCwd: mangled) {
            actionError = error
            return
        }

        await refreshSessionIndex()
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
        guard prepareResumeAccount(sessionId: session.id, cwd: session.cwd,
                                   fromAccount: session.accountName, to: account) else { return }
        let title = session.title ?? (session.cwd as NSString).lastPathComponent
        await launchClaude(cwd: session.cwd, title: title, account: account, resume: session.id,
                           model: effectiveModel(cwd: session.cwd, account: account),
                           effort: effectiveEffort(cwd: session.cwd, account: account))
    }

    /// Prepares a resume that may target a DIFFERENT account than the session
    /// belongs to: when `account` differs from `fromAccount`, both are linked into
    /// the canonical store so the transcript is visible under the new account.
    /// Returns false (and sets `actionError`) when the move is blocked; true when
    /// same-account (a no-op) or successfully linked. Shared by `resumeSession` and
    /// the config-sheet `confirmLaunch` path.
    private func prepareResumeAccount(sessionId: String, cwd: String,
                                      fromAccount: String, to account: AccountConfig) -> Bool {
        guard account.name != fromAccount else { return true }
        if let other = sessionLiveUnderOtherAccount(sessionId, launchAccount: account) {
            actionError = "This session is live under “\(other)” — close it first, "
                + "then resume as \(account.name)."
            return false
        }
        guard canonicalAccount != nil else {
            actionError = "Can't share sessions without a canonical account: add an "
                + "account whose config dir is ~/.claude (the default account)."
            return false
        }
        guard let owner = config.accounts.first(where: { $0.name == fromAccount }) else {
            actionError = "Can't resume as \(account.name): the owning account "
                + "“\(fromAccount)” is no longer configured."
            return false
        }
        let mangled = ClaudeService.mangle(cwd)
        // Link the owner first (so the transcript migrates into canonical),
        // then the target (so the symlinked store makes it visible).
        if let error = ensureLinkedForResume(owner, mangledCwd: mangled) {
            actionError = error
            return false
        }
        if let error = ensureLinkedForResume(account, mangledCwd: mangled) {
            actionError = error
            return false
        }
        return true
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
    /// Whether THIS refresh may talk to Anthropic's usage API. The caller decides —
    /// it used to be inferred from `isPanelOpen`, which meant the 15s liveness loop
    /// re-fetched limits all day, burned rate limit, and (see `lastOAuthSnapshot`)
    /// made the OAuth-only bars blink.
    public enum OAuthPolicy: Sendable, Equatable {
        /// Local statusline captures only. The liveness tick and the background
        /// menu-bar timer: neither needs the API, and the menu-bar readout is built
        /// from the statusline weekly window, which costs no keychain access.
        case skip
        /// One request per account, served from the client's 180s cache when warm.
        /// This is what opening the panel means: "show me current limits". Automatic,
        /// so `config.usage.oauthLiveEnabled` can switch it off.
        case fetch
        /// The refresh button: bypass the result cache. Still honours the 429
        /// backoff — a user holding the button must not earn a longer ban. A direct
        /// gesture, so it is NOT subject to the automatic-fetch setting; a button that
        /// silently did nothing would be worse than no button.
        case force
    }

    public func refreshUsage(now: Date, oauth policy: OAuthPolicy = .skip) async {
        let wantsOAuth: Bool
        switch policy {
        case .skip:  wantsOAuth = false
        case .fetch: wantsOAuth = config.usage.oauthLiveEnabled
        case .force: wantsOAuth = true
        }
        // Only a pass that actually goes to the network shows the loading indicator;
        // otherwise it would flash on every liveness tick.
        if wantsOAuth { isRefreshingUsage = true }
        defer { if wantsOAuth { isRefreshingUsage = false } }
        let analytics = usageAnalytics
        let jobs: [(name: String, dir: String, claudeJSON: String)] = config.accounts.map {
            (name: $0.name, dir: expandTilde($0.configDir), claudeJSON: claudeJSONPath(for: $0))
        }
        let started = Date()
        let ledgerStore = usageLedgerStore
        let inLedgers = usageLedgerByAccount
        let result = await Task.detached(priority: .utility) {
            () -> (snaps: [String: [UsageSnapshot]], byAcc: [String: AccountUsageAnalytics],
                   tiers: [String: String], ids: [String: AccountIdentity],
                   baseLedgers: [String: UsageCostLedger]) in
            let reader = UsageReader()
            var snaps: [String: [UsageSnapshot]] = [:]
            var byAcc: [String: AccountUsageAnalytics] = [:]
            var tiers: [String: String] = [:]
            var ids: [String: AccountIdentity] = [:]
            var baseLedgers: [String: UsageCostLedger] = [:]
            for job in jobs {
                snaps[job.name] = reader.read(configDir: job.dir, accountName: job.name)
                byAcc[job.name] = analytics.account(configDir: job.dir, accountName: job.name,
                                                    claudeJSONPath: job.claudeJSON, now: now)
                // .claude.json read off-main here (was a per-render main-thread read via
                // tier(for:) and AccountsScreen's identity provider).
                if let t = ClaudeService.organizationRateLimitTier(claudeJSONPath: job.claudeJSON) {
                    tiers[job.name] = t
                }
                if let id = ClaudeService.identity(claudeJSONPath: job.claudeJSON) {
                    ids[job.name] = id
                }
                // Load the baseline ledger off-main (cold-start disk read). The actual FOLD runs
                // on the main actor below, from the LIVE ledger, so two concurrent refreshes
                // (panel + timer) can't race the cumulative cursor.
                baseLedgers[job.name] = inLedgers[job.name] ?? ledgerStore.load(account: job.name)
            }
            return (snaps, byAcc, tiers, ids, baseLedgers)
        }.value
        var snaps = result.snaps
        // OAuth limits from Anthropic's usage API. It requires a KEYCHAIN read and it is
        // rate-limited, so it is fetched only when the caller says so (panel opened, or
        // the refresh button) — never on the liveness tick or the background timer.
        if wantsOAuth {
            let bypassCache = policy == .force
            // Report the FIRST failure across accounts, and only when no account
            // succeeded — one broken account among several should not label the whole
            // panel as failing when the bars it drew are current.
            var firstFailure: String?
            var anySucceeded = false
            for job in jobs {
                let usage: OAuthUsage?
                if let override = oauthLimitsOverride {
                    usage = await override(job.dir, now)
                } else {
                    do {
                        usage = try await oauthClient.usage(configDir: job.dir, now: now,
                                                            force: bypassCache)
                    } catch {
                        usage = nil
                        let text = Self.usageErrorText(error)
                        GroveLog.perf.error("oauth usage failed for \(job.name, privacy: .public): \(text, privacy: .public)")
                        if firstFailure == nil { firstFailure = text }
                    }
                }
                guard let usage,
                      let snap = Self.oauthSnapshot(accountName: job.name, usage: usage, now: now)
                else { continue }
                anySucceeded = true
                lastOAuthSnapshot[job.name] = snap
            }
            usageFetchError = anySucceeded ? nil : firstFailure
        }
        // Re-attach each account's newest known OAuth capture whether or not THIS pass
        // fetched. The capture is synthetic — nothing writes it to `grove/usage`, and the
        // block above rebuilds `snaps` from disk every time — so without this the windows
        // that ONLY the API supplies would vanish on any pass that didn't fetch: a
        // liveness tick, a 429 backoff (up to an hour), a transient error. The
        // model-scoped bar is exactly such a window: the live endpoint returns null for
        // every top-level per-model key, so `limits[] weekly_scoped` is its only source
        // and it has nothing to fall back on. Retained captures keep their ORIGINAL
        // `capturedAt`, so the footer still reports the true age and the staleness checks
        // in `currentWindow` still fire once a window's reset passes.
        let liveNames = Set(config.accounts.map(\.name))
        lastOAuthSnapshot = lastOAuthSnapshot.filter { liveNames.contains($0.key) }
        for job in jobs where liveNames.contains(job.name) {
            if let retained = lastOAuthSnapshot[job.name] {
                snaps[job.name, default: []].append(retained)
            }
        }
        snapshotsByAccount = snaps
        usageDataAsOf = snaps.values.flatMap { $0 }.compactMap(\.capturedAt).max()
        usageByAccount = result.byAcc
        tierCache = result.tiers
        identityByAccount = result.ids
        // Fold the cost ledger on the MAIN actor (serial — no two refreshes interleave here) from
        // the LIVE in-memory ledger, falling back to the off-main-loaded baseline only when an
        // account isn't tracked yet (cold start). Fold the pre-OAuth STATUSLINE snapshots
        // (`result.snaps`); the synthetic "oauth" capture is excluded by `fold` anyway. Persist
        // only changed accounts, off-main (fire-and-forget; the in-memory state is the truth).
        // Live accounts only: an account removed during this refresh's awaits must NOT be
        // resurrected in memory or have its deleted ledger file re-created.
        let liveAccounts = Set(config.accounts.map(\.name))
        var ledgers = usageLedgerByAccount.filter { liveAccounts.contains($0.key) }
        for job in jobs where liveAccounts.contains(job.name) {
            var ledger = ledgers[job.name] ?? result.baseLedgers[job.name] ?? UsageCostLedger()
            if UsageCostLedger.fold(into: &ledger, snapshots: result.snaps[job.name] ?? [], now: now) {
                // Stamp a monotonic generation (we're on the serialized main actor) and persist
                // via the serial writer, which skips any out-of-order stale write.
                ledgerGeneration[job.name, default: 0] += 1
                let gen = ledgerGeneration[job.name] ?? 0
                let store = ledgerStore
                let writer = ledgerWriter
                let saved = ledger
                Task { await writer.save(account: job.name, ledger: saved, generation: gen, store: store) }
            }
            ledgers[job.name] = ledger
        }
        usageLedgerByAccount = ledgers
        GroveLog.perf.info("usage refresh (\(jobs.count) accts, oauth=\(wantsOAuth)): \(Int(Date().timeIntervalSince(started) * 1000))ms")
    }

    /// A short, user-facing reason a usage fetch failed. Deliberately actionable: each
    /// case tells the user whether to wait, to sign in, or that the problem is ours.
    static func usageErrorText(_ error: Error) -> String {
        switch error {
        case OAuthUsageError.noCredentials:   return "No Claude credentials found"
        case OAuthUsageError.tooManyRequests: return "Rate limited — try again shortly"
        case OAuthUsageError.backoff:         return "Rate limited — waiting to retry"
        case OAuthUsageError.malformed:       return "Unexpected response from Anthropic"
        case OAuthUsageError.http(401), OAuthUsageError.http(403):
            return "Claude sign-in expired — run `claude` to refresh it"
        case OAuthUsageError.http(let status): return "Anthropic returned HTTP \(status)"
        default: return (error as NSError).localizedDescription
        }
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
        let opus = window(usage.sevenDayOpus)
        let fable = window(usage.sevenDayFable)
        // Plumb the limits[]-derived model-scoped window. This is the PRIMARY source
        // for the per-model bar — title and utilization come from the weekly_scoped entry.
        let scopedWindow: CapturedWindow?
        if let s = usage.weeklyScoped {
            scopedWindow = CapturedWindow(usedPercentage: min(max(s.utilization, 0), 100),
                                          resetsAt: s.resetsAt)
        } else {
            scopedWindow = nil
        }
        let scopedModel = usage.weeklyScoped?.modelDisplayName
        guard five != nil || seven != nil || sonnet != nil || opus != nil || fable != nil
                || scopedWindow != nil else { return nil }
        // Dated by the FETCH, not by this tick: a 180s cache hit carries the instant of
        // the original request, so the panel's "Updated …" line can't claim stale numbers
        // are current. nil (canned test values) falls back to the tick.
        return UsageSnapshot(accountName: accountName, sessionId: "oauth",
                             capturedAt: usage.fetchedAt ?? now, cwd: nil,
                             modelId: nil, modelDisplayName: nil, effort: nil,
                             contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                             fiveHour: five, sevenDay: seven, sevenDaySonnet: sonnet,
                             sevenDayOpus: opus, sevenDayFable: fable,
                             weeklyScopedWindow: scopedWindow, weeklyScopedModel: scopedModel)
    }

    private func tier(for account: AccountConfig) -> String? {
        if let t = tierOverride?[account.name] { return t }
        // In-memory only: the canonical organizationRateLimitTier is read from
        // .claude.json off-main during refreshUsage and cached in tierCache. NEVER
        // read the file here — tier(for:) runs inside view bodies via aggregateRemaining.
        return tierCache[account.name]
    }

    private func claudeJSONPath(for account: AccountConfig) -> String {
        let dir = expandTilde(account.configDir)
        return dir == NSHomeDirectory() + "/.claude"
            ? NSHomeDirectory() + "/.claude.json" : dir + "/.claude.json"
    }

    /// Overall WEEKLY limit for the menu-bar readout: the tier-weighted USED
    /// percentage across all accounts and its capacity level (drives the colour).
    /// nil until there's data to show. Same thresholds as the Weekly limit card.
    public func menuBarWeeklyUsage(now: Date = Date()) -> (percent: Int, level: CapacityLevel)? {
        let agg = aggregateRemaining(window: .sevenDay, now: now)
        guard agg.total > 0 else { return nil }
        let used = (1 - agg.fraction) * 100
        let remaining = max(0, 1 - used / 100)
        let level: CapacityLevel = remaining > 0.5 ? .plenty : (remaining > 0.1 ? .tight : .critical)
        return (Int(used.rounded()), level)
    }

    /// Every account's resolved limit windows + tier. The SINGLE source the Overall
    /// column and the menu-bar readout both aggregate from, so the panel and the
    /// menu bar can never report different numbers for the same window.
    ///
    /// Resolution goes through `currentWindow` — the SAME function the per-account
    /// columns use — so Overall's per-account chip and that account's own bar are the
    /// same number by construction. They diverged while this path had its own
    /// statusline-preferring resolver. An account whose statusline lacks rate_limits
    /// still contributes from OAuth; only a window absent from every capture drops out.
    public func accountLimitInputs(now: Date) -> [AccountLimitInput] {
        config.accounts.map { account in
            let snaps = snapshotsByAccount[account.name] ?? []
            let scoped = modelScopedWindow(latestModelId: resolveLatestModelId(snaps),
                                           snapshots: snaps, now: now)
            return AccountLimitInput(
                account: account.name,
                tier: tier(for: account),
                fiveHour: currentWindow(snaps, Self.pick(.fiveHour), now: now),
                weekly: currentWindow(snaps, Self.pick(.sevenDay), now: now),
                weeklySonnet: currentWindow(snaps, Self.pick(.sevenDaySonnet), now: now),
                scopedModel: scoped?.model,
                scopedWindow: scoped?.window)
        }
    }

    /// Aggregate remaining capacity for a window across accounts (spec §C.3): each
    /// account weighted by tier, combined with its most-recent capture's used%.
    public func aggregateRemaining(window: LimitWindow, now: Date) -> RateLimitModel.Aggregate {
        let accounts: [RateLimitModel.AccountWindow] = accountLimitInputs(now: now).compactMap { input in
            let captured: CapturedWindow?
            switch window {
            case .fiveHour:       captured = input.fiveHour
            case .sevenDay:       captured = input.weekly
            case .sevenDaySonnet: captured = input.weeklySonnet
            }
            guard let used = captured?.usedPercentage else { return nil }
            return RateLimitModel.AccountWindow(tier: input.tier, usedPercentage: used)
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
            return currentWindow(snaps, Self.pick(window), now: now)
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
    /// Failures land in actionError; nothing is mutated on failure. This is the
    /// user-facing toggle; the auto-install sites (addAccount/linkAccount/
    /// migrateSession) share the same core via `enableMonitoring(_:)`.
    public func installMonitoring(_ account: AccountConfig) {
        enableMonitoring(account, reportErrors: true)
    }

    /// Shared statusline auto-install: ensures the account's configDir exists, ships
    /// the (idempotent, original-preserving) grove wrapper, repoints its settings.json,
    /// and records monitoring=true + savedStatusline. Best-effort — the whole point of
    /// auto-installing at account-setup time (Phase 5A) is capture-by-default, so a
    /// failure must never abort the surrounding action (addAccount/linkAccount/
    /// migrateSession). `reportErrors` surfaces failures in `actionError` only for the
    /// explicit user toggle; the auto sites stay silent.
    ///
    /// Re-runs are safe: `StatuslineInstaller.install` recovers the true original from
    /// the previously-baked wrapper, so calling this on an already-monitored account
    /// preserves — never clobbers — the saved original.
    private func enableMonitoring(_ account: AccountConfig, reportErrors: Bool) {
        let dir = expandTilde(account.configDir)
        // The wrapper writes <configDir>/settings.json; the dir must exist first
        // (addAccount's ~/.claude-accounts/<name> is brand-new and empty).
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let installer = StatuslineInstaller(scriptDir: statuslineScriptDir)
        let saved: String?
        do { saved = try installer.install(configDir: dir) }
        catch {
            if reportErrors {
                actionError = "Couldn't enable monitoring for “\(account.name)”: \(error.localizedDescription)"
            }
            return
        }
        guard let i = config.accounts.firstIndex(where: { $0.name == account.name }) else { return }
        config.accounts[i].monitoring = true
        config.accounts[i].monitoringDisabledByUser = false
        config.accounts[i].savedStatusline = saved
        persist()
    }

    /// Restores the saved original statusline command and clears monitoring.
    /// Sets `monitoringDisabledByUser=true` so reconcileMonitoring knows not to
    /// silently re-enable this account on the next launch.
    public func disableMonitoring(_ account: AccountConfig) {
        let installer = StatuslineInstaller(scriptDir: statuslineScriptDir)
        let dir = expandTilde(account.configDir)
        do { try installer.uninstall(configDir: dir, savedStatusline: account.savedStatusline) }
        catch { actionError = "Couldn't disable monitoring for \"\(account.name)\": \(error.localizedDescription)"; return }
        guard let i = config.accounts.firstIndex(where: { $0.name == account.name }) else { return }
        config.accounts[i].monitoring = false
        config.accounts[i].monitoringDisabledByUser = true
        config.accounts[i].savedStatusline = nil
        persist()
    }

    /// Launch reconcile (Phase 5A): auto-installs the grove statusline wrapper for
    /// every configured account not yet monitored AND not explicitly disabled by the
    /// user — so accounts created before 5A (or an account whose monitoring was never
    /// enabled, e.g. icloud) start capturing usage. Accounts where the user explicitly
    /// ran `disableMonitoring` are skipped (monitoringDisabledByUser=true), so the
    /// user's intent is respected across launches. Best-effort per account: a
    /// missing/locked config dir is skipped without surfacing an error.
    /// File I/O runs off-main to keep launch responsive.
    public func reconcileMonitoring() {
        // Gather accounts needing install on the main actor, then do file I/O off-main.
        let toInstall = config.accounts.filter { !$0.monitoring && !$0.monitoringDisabledByUser }
        guard !toInstall.isEmpty else { return }
        let scriptDir = statuslineScriptDir
        Task.detached(priority: .utility) { [weak self] in
            // Run install file I/O per account off the main thread.
            var installed: [(name: String, savedStatusline: String?)] = []
            for account in toInstall {
                let dir = expandTilde(account.configDir)
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let installer = StatuslineInstaller(scriptDir: scriptDir)
                if let saved = try? installer.install(configDir: dir) {
                    installed.append((name: account.name, savedStatusline: saved))
                }
            }
            // Hop back to main actor to persist config changes.
            await MainActor.run { [weak self] in
                guard let self else { return }
                for result in installed {
                    guard let i = self.config.accounts.firstIndex(where: { $0.name == result.name }) else { continue }
                    self.config.accounts[i].monitoring = true
                    self.config.accounts[i].savedStatusline = result.savedStatusline
                }
                if !installed.isEmpty { self.persist() }
            }
        }
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

    /// The directory holding per-account usage-cost ledger files. Production:
    /// ~/Library/Application Support/Grove/usageledger; tests inject usageLedgerStoreDirOverride.
    private var usageLedgerStoreDir: URL {
        if let override = usageLedgerStoreDirOverride { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grove/usageledger")
    }
    var usageLedgerStore: UsageCostLedgerStore { UsageCostLedgerStore(dir: usageLedgerStoreDir) }

    /// The per-UTC-day cost deltas the chart merges in for one account: ONLY days the ledger has
    /// actually recorded a delta for (membership = "Grove tracked this day"). Pre-tracking days
    /// are absent, so the chart keeps their transcript-derived cost; tracked days use the ledger.
    public func ledgerCostByDay(forAccount name: String) -> [Date: Double] {
        (usageLedgerByAccount[name] ?? UsageCostLedger()).costByDay
    }

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

        if statsRescanStartedCount != nil { statsRescanStartedCount! += 1 }
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
    /// from the working tree and is branch-independent, so it stays put). The dict
    /// write is OPTIMISTIC (immediate) so the chip label updates at once; the rescan
    /// is DEBOUNCED — rapid picks cancel the pending task and schedule a new one so
    /// N consecutive switches coalesce to one scan. Honors the per-project scan
    /// serialization via refreshCodeStats.
    public func setStatsBranch(projectID: UUID, repoPath: String, branch: String) {
        // Optimistic: the chip shows the new label immediately (no wait for rescan).
        selectedStatsBranchByRepo[repoPath] = branch
        // Debounce: cancel any pending rescan and schedule a fresh one after the interval.
        statsBranchDebounce?.cancel()
        let interval = statsBranchDebounceInterval
        statsBranchDebounce = Task {
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await refreshCodeStats(projectID: projectID)
        }
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

    /// Builds the "Tokens per 100 net lines" cumulative series for a project (Phase 5D).
    ///
    /// Resolves the project's canonical cwd roots (its `path` and `workspacesRoot` plus
    /// any cwds seen in `codeStatsHistory`), collects `dailyByCwd` from every account in
    /// `usageByAccount`, and delegates the join + cumulative math to the pure presentation
    /// function `tokensPerNetLine`. Returns `[]` when the project is unknown.
    public func tokensPerLineSeries(projectID: UUID) -> [RatioPoint] {
        guard let project = config.projects.first(where: { $0.id == projectID }) else { return [] }

        // Canonical cwd roots for this project.
        var projectCwds: [String] = []
        if !project.path.isEmpty {
            projectCwds.append(expandTilde(project.path))
        }
        if let root = project.workspacesRoot, !root.isEmpty {
            projectCwds.append(expandTilde(root))
        }
        // Also include any cwds seen in the code-stats history (worktrees may differ from path).
        if let history = codeStatsHistory[projectID] {
            for point in history {
                // codeStatsHistory points don't carry cwd; the project roots above cover it.
                // This no-op loop is left as extension point for future per-worktree series.
                _ = point
            }
        }

        // Gather dailyByCwd from every account.
        let tokensByAccount: [[String: [DayUsage]]] = config.accounts.compactMap { account in
            usageByAccount[account.name]?.dailyByCwd
        }

        let history = codeStatsHistory[projectID] ?? []
        return tokensPerNetLine(
            tokenDailyByCwdPerAccount: tokensByAccount,
            projectCwds: projectCwds,
            codeHistory: history,
            now: Date()
        )
    }
}
