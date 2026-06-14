import AppKit
import SwiftUI
import GroveCore

/// Pre-expanded workspace names for the "workspaces-expanded" snapshot scene.
/// The placeholder RootView ignores it; WorkspacesScreen (Task 19) consumes it
/// to render expanded WorkspaceRowCards without interaction.
struct SnapshotExpandedWorkspacesKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
    var snapshotExpandedWorkspaces: Set<String> {
        get { self[SnapshotExpandedWorkspacesKey.self] }
        set { self[SnapshotExpandedWorkspacesKey.self] = newValue }
    }
}

/// Agent-verifiable UI harness: `GroveApp --snapshot <outDir>` renders the app
/// with a synthetic fixture state into PNGs and exits without ever starting
/// NSApplication. Rich fixture (4 workspaces incl. one stacked child, all four
/// age buckets, busy/waiting/resumable mixes, 2 loose worktrees); every scene
/// renders RootView with the scene's ROUTE set (the panel is a state machine
/// of full-screen views) at that route's adaptive panel size.
public enum SnapshotMode {
    enum SnapshotError: Error, CustomStringConvertible {
        case renderFailed(String)
        case encodeFailed(String)

        var description: String {
            switch self {
            case .renderFailed(let name): return "ImageRenderer produced no image for \(name)"
            case .encodeFailed(let name): return "PNG encoding failed for \(name)"
            }
        }
    }

    enum SnapshotScene: String, CaseIterable {
        case projects = "projects"
        case charts = "charts"
        case rootWorkspaces = "root-workspaces"
        case workspacesExpanded = "workspaces-expanded"
        case createSheet = "create-sheet"
        case graph = "graph"
        case sessions = "sessions"
        case accounts = "accounts"
        case accountsUsage = "accounts-usage"
        case settings = "settings"
        case errorBanner = "error-banner"

        var fileName: String { rawValue + ".png" }

        /// Canvas size = the route's adaptive panel frame (RootView).
        /// error-banner adds vertical allowance on top of the projects frame
        /// because RootView stacks the banner ABOVE the routed screen.
        var size: CGSize {
            switch self {
            case .projects: return CGSize(width: 460, height: 520)
            case .charts: return CGSize(width: 290, height: 800)
            case .rootWorkspaces, .workspacesExpanded, .graph, .sessions:
                return CGSize(width: 760, height: 540)
            case .createSheet: return CGSize(width: 540, height: 560)
            case .accounts, .accountsUsage: return CGSize(width: 560, height: 480)
            case .settings: return CGSize(width: 560, height: 560)
            case .errorBanner: return CGSize(width: 460, height: 584)
            }
        }
    }

    /// True (and never actually returns: exit() inside) when "--snapshot <dir>"
    /// is present; false when absent so main.swift starts the real app.
    @MainActor
    public static func runIfRequested() -> Bool {
        guard let outDir = parseSnapshotDir(from: CommandLine.arguments) else { return false }
        do {
            let count = try renderAll(into: URL(fileURLWithPath: outDir, isDirectory: true))
            print("snapshot: \(count) files")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Pure: the value following "--snapshot", nil when the flag is absent or last.
    static func parseSnapshotDir(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--snapshot"),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    // MARK: - Fixture

    /// Synthetic AppState: no disk scanning, no git, no real config file.
    /// The ConfigStore points at a non-existent temp path, so load() yields
    /// defaults and nothing is ever written. Public so tests reuse the fixture.
    @MainActor
    public static func fixtureState() -> AppState {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-snapshot-\(UUID().uuidString)/config.json")
        let state = AppState(configStore: ConfigStore(url: url))

        let project = ProjectConfig(
            id: UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!,
            name: "acme.shop",
            path: "/Users/demo/Desktop/acme.shop",
            workspacesRoot: "/Users/demo/Workspaces/acme.shop",
            baseBranchOverrides: ["acme-server-config-a": "docker"],
            defaultAccount: "work"      // settings.png shows the account picker non-empty
        )
        state.config = GroveConfig(
            version: 1,
            workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [project],
            accounts: [
                AccountConfig(name: "default", configDir: "~/.claude"),
                AccountConfig(name: "work", configDir: "~/.claude-accounts/work", sharedStore: true),
            ]
        )
        let now = Date()
        state.snapshots = [project.id: fixtureSnapshot(project: project, now: now)]
        state.selectedProjectID = project.id
        // What loadBranches would find — offscreen renders must not run git.
        // Each list contains the repo's resolved default start point, so the
        // create-sheet/settings pickers show real selections in the PNGs.
        state.branchesByRepo = [
            project.path + "/acme_client":
                ["dev", "feat/folders-followup", "feat/media-pipeline",
                 "feat/media-upload", "main"],
            project.path + "/acme_server":
                ["feat/media-pipeline", "feat/media-upload", "master"],
            project.path + "/acme-server-config-a":
                ["docker", "feat/live-tier-redis", "main"],
        ]
        state.graphRepoPath = project.path + "/acme_client"
        state.graphNodes = fixtureGraphNodes(now: now)

        // Usage fixture (Task 12): deterministic analytics + captures so the
        // accounts-usage scene renders bars/cards/token+cost tables/breakdown
        // and every header chip shows a real aggregate. Reset countdowns use
        // the fixture `now`, so they stay stable across renders.
        state.snapshotsByAccount = fixtureSnapshotsByAccount(now: now)
        state.usageByAccount = fixtureUsageByAccount(now: now)
        // Internally-consistent tier namespace (FIX I2): the SAME canonical
        // strings the Accounts card (organizationRateLimitTier) and
        // RateLimitModel.tierWeights key on, so the aggregate badge weights
        // correctly and accounts.png / accounts-usage.png never show a
        // max_20x vs default_claude_max_20x mismatch.
        state.tierOverride = ["default": "default_claude_max_20x",
                              "work": "default_claude_max_5x"]

        // Projects-tab session previews (item 4): a running session mapped to a
        // cmux workspace (Go) and a waiting one (Resume).
        let wsRoot = "/Users/demo/Workspaces/acme.shop"
        state.recentSessionsByProject = [project.id: [
            ProjectSessionRow(sessionId: "s-mp-1", title: "media pipeline retries",
                              cwd: wsRoot + "/media-pipeline", location: "media-pipeline",
                              accountName: "default", lastActivity: now.addingTimeInterval(-900),
                              status: .running, cmuxWorkspaceId: "ws-101"),
            ProjectSessionRow(sessionId: "s-mu-1", title: "upload endpoint",
                              cwd: wsRoot + "/media-upload", location: "media-upload",
                              accountName: "work", lastActivity: now.addingTimeInterval(-120),
                              status: .waiting, cmuxWorkspaceId: nil),
        ]]
        return state
    }

    // MARK: - Usage fixtures (Task 12)

    /// ISO8601 (`.withInternetDateTime`) string for a reset instant relative to
    /// the fixture `now`, so `RateLimitModel.window` parses a stable countdown.
    private static let isoReset: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Most-recent statusline captures per account. The accounts-usage scene
    /// renders 5h/weekly bars from these; `aggregateRemaining` reads the latest
    /// capture's `fiveHour`/`sevenDay` used% for the header chip.
    ///   default: 5h 30% (resets in 2h), weekly 45%
    ///   work:    5h 70% (resets in 1h), weekly 60%
    static func fixtureSnapshotsByAccount(now: Date) -> [String: [UsageSnapshot]] {
        func reset(_ seconds: TimeInterval) -> String {
            isoReset.string(from: now.addingTimeInterval(seconds))
        }
        let defaultSnap = UsageSnapshot(
            accountName: "default", sessionId: "s-mp-1",
            capturedAt: now.addingTimeInterval(-900),
            cwd: "/Users/demo/Workspaces/acme.shop/media-pipeline",
            modelId: "claude-opus-4-8", modelDisplayName: "Opus 4.8",
            effort: "high", contextUsedPercentage: 42,
            totalInputTokens: 184_300, totalCostUSD: 6.42,
            fiveHour: CapturedWindow(usedPercentage: 30, resetsAt: reset(2 * 3_600)),
            sevenDay: CapturedWindow(usedPercentage: 45, resetsAt: reset(3 * 86_400)),
            sevenDaySonnet: CapturedWindow(usedPercentage: 22, resetsAt: reset(3 * 86_400)))
        // Two COMPLETED 5h sessions (reset in the past) so the session-trend
        // (avg/prev) renders: peaks 53% then 40% → avg 46%, prev 53%.
        func histSnap(_ id: String, used: Double, resetAgo: TimeInterval) -> UsageSnapshot {
            UsageSnapshot(accountName: "default", sessionId: id, capturedAt: now.addingTimeInterval(-resetAgo),
                          cwd: nil, modelId: nil, modelDisplayName: nil, effort: nil,
                          contextUsedPercentage: nil, totalInputTokens: nil, totalCostUSD: nil,
                          fiveHour: CapturedWindow(usedPercentage: used, resetsAt: reset(-resetAgo)),
                          sevenDay: nil)
        }
        let hist = [histSnap("s-h1", used: 53, resetAgo: 5 * 3_600),
                    histSnap("s-h2", used: 40, resetAgo: 10 * 3_600)]
        let workSnap = UsageSnapshot(
            accountName: "work", sessionId: "s-mu-1",
            capturedAt: now.addingTimeInterval(-120),
            cwd: "/Users/demo/Workspaces/acme.shop/media-upload",
            modelId: "claude-sonnet-4-6", modelDisplayName: "Sonnet 4.6",
            effort: "medium", contextUsedPercentage: 18,
            totalInputTokens: 92_100, totalCostUSD: 1.87,
            fiveHour: CapturedWindow(usedPercentage: 70, resetsAt: reset(1 * 3_600)),
            sevenDay: CapturedWindow(usedPercentage: 60, resetsAt: reset(4 * 86_400)),
            sevenDaySonnet: CapturedWindow(usedPercentage: 35, resetsAt: reset(4 * 86_400)))
        return ["default": [defaultSnap] + hist, "work": [workSnap]]
    }

    /// 7 calendar-day token buckets with a reference-like profile (a couple of
    /// heavy days, a light "today") so the Daily Usage chart shows colour variety.
    static func fixtureDaily(now: Date, scale: Double) -> [DayUsage] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let today = cal.startOfDay(for: now)
        let profile = [0, 0, 0, 900_000, 760_000, 420_000, 60_000]
        return (0..<7).map { i in
            let tokens = Int(Double(profile[i]) * scale)
            let day = cal.date(byAdding: .day, value: -(6 - i), to: today)!
            return DayUsage(day: day, inputTokens: tokens / 6, outputTokens: tokens / 12,
                            cacheTokens: tokens, cost: Double(tokens) / 120_000)
        }
    }

    /// Per-account analytics: today/month token+cost rollups, per-model cost for
    /// the breakdown %, and a `sessions` entry per fixture session id so the
    /// session cards show real numbers. Account-of-record matches each fixture
    /// ClaudeSession's `accountName`.
    static func fixtureUsageByAccount(now: Date) -> [String: AccountUsageAnalytics] {
        let root = "/Users/demo/Workspaces/acme.shop"
        let opus = "claude-opus-4-8"
        let sonnet = "claude-sonnet-4-6"

        // default account: media-pipeline (s-mp-1), folders-followup (s-ff-1),
        // group-chats loose (s-gc-1), media-upload retry (s-mu-2).
        let defaultSessions: [String: SessionUsage] = [
            "s-mp-1": SessionUsage(sessionId: "s-mp-1", cwd: root + "/media-pipeline",
                inputTokens: 184_300, outputTokens: 38_900, cost: 6.42,
                modelBreakdown: [opus: 170_000, sonnet: 53_200],
                lastActivity: now.addingTimeInterval(-900)),
            "s-ff-1": SessionUsage(sessionId: "s-ff-1", cwd: root + "/folders-followup",
                inputTokens: 42_100, outputTokens: 9_800, cost: 1.31,
                modelBreakdown: [sonnet: 51_900],
                lastActivity: now.addingTimeInterval(-20 * 86_400)),
            "s-gc-1": SessionUsage(sessionId: "s-gc-1",
                cwd: "/Users/demo/Desktop/acme.shop/acme_client/.worktrees/group-chats",
                inputTokens: 17_400, outputTokens: 4_100, cost: 0.58,
                modelBreakdown: [sonnet: 21_500],
                lastActivity: now.addingTimeInterval(-9 * 86_400)),
            "s-mu-2": SessionUsage(sessionId: "s-mu-2", cwd: root + "/media-upload",
                inputTokens: 8_900, outputTokens: 2_300, cost: 0.27,
                modelBreakdown: [sonnet: 11_200],
                lastActivity: now.addingTimeInterval(-1 * 86_400)),
        ]
        let defaultAnalytics = AccountUsageAnalytics(
            accountName: "default",
            today: UsageTotals(inputTokens: 184_300, outputTokens: 38_900,
                               cacheReadTokens: 920_000, cacheWrite5mTokens: 41_000,
                               cacheWrite1hTokens: 6_000, cost: 6.42),
            thisMonth: UsageTotals(inputTokens: 1_640_500, outputTokens: 312_400,
                                   cacheReadTokens: 8_900_000, cacheWrite5mTokens: 410_000,
                                   cacheWrite1hTokens: 52_000, cost: 58.71),
            last7d: UsageTotals(inputTokens: 612_300, outputTokens: 121_900,
                                cacheReadTokens: 3_100_000, cacheWrite5mTokens: 150_000,
                                cacheWrite1hTokens: 18_000, cost: 22.18),
            daily: fixtureDaily(now: now, scale: 1.0),
            sessions: defaultSessions,
            costByModel: [opus: 51.90, sonnet: 6.81],
            byCwd: [
                root + "/media-pipeline": UsageTotals(inputTokens: 184_300, cost: 6.42),
                root + "/folders-followup": UsageTotals(inputTokens: 42_100, cost: 1.31),
            ],
            unpricedModels: [], unpricedCost: 0)

        // work account: media-upload endpoint (s-mu-1), migration dry-run (s-ff-2).
        let workSessions: [String: SessionUsage] = [
            "s-mu-1": SessionUsage(sessionId: "s-mu-1", cwd: root + "/media-upload",
                inputTokens: 92_100, outputTokens: 21_400, cost: 1.87,
                modelBreakdown: [sonnet: 113_500],
                lastActivity: now.addingTimeInterval(-120)),
            "s-ff-2": SessionUsage(sessionId: "s-ff-2", cwd: root + "/folders-followup",
                inputTokens: 14_200, outputTokens: 3_600, cost: 0.41,
                modelBreakdown: [sonnet: 17_800],
                lastActivity: now.addingTimeInterval(-21 * 86_400)),
        ]
        let workAnalytics = AccountUsageAnalytics(
            accountName: "work",
            today: UsageTotals(inputTokens: 92_100, outputTokens: 21_400,
                               cacheReadTokens: 430_000, cacheWrite5mTokens: 22_000,
                               cacheWrite1hTokens: 3_000, cost: 1.87),
            thisMonth: UsageTotals(inputTokens: 740_200, outputTokens: 158_700,
                                   cacheReadTokens: 3_900_000, cacheWrite5mTokens: 190_000,
                                   cacheWrite1hTokens: 24_000, cost: 19.44),
            last7d: UsageTotals(inputTokens: 281_500, outputTokens: 61_200,
                                cacheReadTokens: 1_500_000, cacheWrite5mTokens: 72_000,
                                cacheWrite1hTokens: 9_000, cost: 7.92),
            daily: fixtureDaily(now: now, scale: 0.55),
            sessions: workSessions,
            costByModel: [sonnet: 19.44],
            byCwd: [
                root + "/media-upload": UsageTotals(inputTokens: 92_100, cost: 1.87),
                root + "/folders-followup": UsageTotals(inputTokens: 14_200, cost: 0.41),
            ],
            unpricedModels: [], unpricedCost: 0)

        return ["default": defaultAnalytics, "work": workAnalytics]
    }

    /// Ages are relative to `now` (real clock at render time) because the
    /// views compute badges against Date() — fixed dates would drift.
    ///
    /// Coverage matrix (badge variety per contract):
    ///   media-pipeline   root,  12d aging,  dirty 12, 1 busy,    0 resumable, cmux-mapped
    ///   media-upload     CHILD of media-pipeline, 2d fresh, dirty 3, 1 waiting, 1 resumable
    ///   folders-followup root,  24d stale,  dirty 0,  no live,   2 resumable
    ///   live-tier-redis  root,  meta degraded -> unknown age, nothing else
    ///   loose: group-chats (+9/-3, 1 resumable) and legacy-auth (meta nil)
    static func fixtureSnapshot(project: ProjectConfig, now: Date) -> ProjectSnapshot {
        let root = "/Users/demo/Workspaces/acme.shop"
        let client = RepoInfo(path: project.path + "/acme_client", dirName: "acme_client")
        let server = RepoInfo(path: project.path + "/acme_server", dirName: "acme_server")
        let config = RepoInfo(path: project.path + "/acme-server-config-a",
                              dirName: "acme-server-config-a")

        func day(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }

        // media-pipeline: root workspace, 2 repos, busy Claude, cmux workspace.
        let mpUmbrella = root + "/media-pipeline"
        let mediaPipeline = FeatureWorkspace(
            name: "media-pipeline",
            umbrellaPath: mpUmbrella,
            repos: [
                WorkspaceRepoState(
                    repo: client,
                    entry: WorktreeEntry(path: mpUmbrella + "/acme_client",
                                         branch: "feat/media-pipeline",
                                         head: "aaaa111", isMain: false),
                    meta: WorktreeMeta(baseBranch: "dev", forkPoint: "ffff000",
                                       forkDate: day(12), ahead: 14, behind: 2, dirtyCount: 8,
                                       lastCommitDate: day(0.04),
                                       lastCommitSubject: "wire upload progress events"),
                    scanError: nil),
                WorkspaceRepoState(
                    repo: server,
                    entry: WorktreeEntry(path: mpUmbrella + "/acme_server",
                                         branch: "feat/media-pipeline",
                                         head: "aaaa222", isMain: false),
                    meta: WorktreeMeta(baseBranch: "master", forkPoint: "ffff001",
                                       forkDate: day(12), ahead: 5, behind: 0, dirtyCount: 4,
                                       lastCommitDate: day(0.2),
                                       lastCommitSubject: "media service: chunked uploads"),
                    scanError: nil),
            ],
            parentName: nil,
            sessions: [
                ClaudeSession(id: "s-mp-1", cwd: mpUmbrella,
                              title: "Implement media pipeline",
                              lastActivity: now.addingTimeInterval(-900),
                              accountName: "default",
                              gitBranch: "feat/media-pipeline"),
            ],
            liveProcesses: [
                LiveProcess(pid: 4242, sessionId: "s-mp-1", cwd: mpUmbrella,
                            status: "busy", accountName: "default",
                            startedAt: now.addingTimeInterval(-2_700)),  // 45m runtime
            ],
            cmuxWorkspaces: [
                CmuxWorkspace(id: "ws-101", title: "media-pipeline",
                              currentDirectory: mpUmbrella),
            ]
        )

        // media-upload: STACKED on media-pipeline (meta relative to the parent
        // branch, mirroring WorkspaceService.scan), waiting Claude + 1 resumable.
        let muUmbrella = root + "/media-upload"
        let mediaUpload = FeatureWorkspace(
            name: "media-upload",
            umbrellaPath: muUmbrella,
            repos: [
                WorkspaceRepoState(
                    repo: client,
                    entry: WorktreeEntry(path: muUmbrella + "/acme_client",
                                         branch: "feat/media-upload",
                                         head: "bbbb111", isMain: false),
                    meta: WorktreeMeta(baseBranch: "feat/media-pipeline", forkPoint: "aaaa111",
                                       forkDate: day(2), ahead: 3, behind: 0, dirtyCount: 3,
                                       lastCommitDate: day(0.1),
                                       lastCommitSubject: "upload retry with backoff"),
                    scanError: nil),
                WorkspaceRepoState(
                    repo: server,
                    entry: WorktreeEntry(path: muUmbrella + "/acme_server",
                                         branch: "feat/media-upload",
                                         head: "bbbb222", isMain: false),
                    meta: WorktreeMeta(baseBranch: "feat/media-pipeline", forkPoint: "aaaa222",
                                       forkDate: day(2), ahead: 1, behind: 0, dirtyCount: 0,
                                       lastCommitDate: day(1.5),
                                       lastCommitSubject: "accept multipart on /media"),
                    scanError: nil),
            ],
            parentName: "media-pipeline",
            sessions: [
                ClaudeSession(id: "s-mu-1", cwd: muUmbrella,
                              title: "Multipart upload endpoint",
                              lastActivity: now.addingTimeInterval(-120),
                              accountName: "work",
                              gitBranch: "feat/media-upload"),
                ClaudeSession(id: "s-mu-2", cwd: muUmbrella,
                              title: "Client retry UX",
                              lastActivity: day(1),
                              accountName: "default",
                              gitBranch: "feat/media-upload"),
            ],
            liveProcesses: [
                LiveProcess(pid: 4343, sessionId: "s-mu-1", cwd: muUmbrella,
                            status: "waiting", accountName: "work",
                            startedAt: now.addingTimeInterval(-360)),    // 6m runtime
            ],
            cmuxWorkspaces: []
        )

        // folders-followup: stale root, clean tree, two resumable sessions.
        let ffUmbrella = root + "/folders-followup"
        let foldersFollowup = FeatureWorkspace(
            name: "folders-followup",
            umbrellaPath: ffUmbrella,
            repos: [
                WorkspaceRepoState(
                    repo: client,
                    entry: WorktreeEntry(path: ffUmbrella + "/acme_client",
                                         branch: "feat/folders-followup",
                                         head: "cccc111", isMain: false),
                    meta: WorktreeMeta(baseBranch: "dev", forkPoint: "ffff002",
                                       forkDate: day(24), ahead: 9, behind: 6, dirtyCount: 0,
                                       lastCommitDate: day(20),
                                       lastCommitSubject: "folder rename flow"),
                    scanError: nil),
            ],
            parentName: nil,
            sessions: [
                ClaudeSession(id: "s-ff-1", cwd: ffUmbrella,
                              title: "Folder sharing follow-ups",
                              lastActivity: day(20),
                              accountName: "default",
                              gitBranch: "feat/folders-followup"),
                ClaudeSession(id: "s-ff-2", cwd: ffUmbrella,
                              title: "Migration dry-run",
                              lastActivity: day(21),
                              accountName: "work",
                              gitBranch: "feat/folders-followup"),
            ],
            liveProcesses: [],
            cmuxWorkspaces: []
        )

        // live-tier-redis: degraded scan (meta nil -> unknown age), nothing live.
        let ltUmbrella = root + "/live-tier-redis"
        let liveTierRedis = FeatureWorkspace(
            name: "live-tier-redis",
            umbrellaPath: ltUmbrella,
            repos: [
                WorkspaceRepoState(
                    repo: config,
                    entry: WorktreeEntry(path: ltUmbrella + "/acme-server-config-a",
                                         branch: "feat/live-tier-redis",
                                         head: "dddd111", isMain: false),
                    meta: nil,
                    scanError: "git meta timed out after 10s"),
            ],
            parentName: nil,
            sessions: [],
            liveProcesses: [],
            cmuxWorkspaces: []
        )

        // Two loose worktrees (outside the workspaces root, spec §2).
        let gcPath = client.path + "/.worktrees/group-chats"
        let groupChats = LooseWorktree(
            repo: client,
            entry: WorktreeEntry(path: gcPath, branch: "feature/group-chats",
                                 head: "eeee111", isMain: false),
            meta: WorktreeMeta(baseBranch: "dev", forkPoint: "ffff003",
                               forkDate: day(30), ahead: 9, behind: 3, dirtyCount: 0,
                               lastCommitDate: day(9),
                               lastCommitSubject: "group chat read receipts"),
            sessions: [
                ClaudeSession(id: "s-gc-1", cwd: gcPath,
                              title: "Group chats",
                              lastActivity: day(9),
                              accountName: "default",
                              gitBranch: "feature/group-chats"),
            ],
            liveProcesses: [],
            cmuxWorkspaces: []
        )
        let legacyAuth = LooseWorktree(
            repo: server,
            entry: WorktreeEntry(path: server.path + "/.worktrees/legacy-auth",
                                 branch: "legacy-auth",
                                 head: "eeee222", isMain: false),
            meta: nil,
            sessions: [],
            liveProcesses: [],
            cmuxWorkspaces: []
        )

        // Workspaces sorted by name, like WorkspaceService.scan emits them.
        return ProjectSnapshot(
            project: project,
            repos: [config, client, server].sorted { $0.path < $1.path },
            workspaces: [foldersFollowup, liveTierRedis, mediaPipeline, mediaUpload],
            loose: [groupChats, legacyAuth],
            errors: []
        )
    }

    // MARK: - Graph fixture (consumed by GraphScreen in Task 21)

    /// Hand-laid-out commit topology: trunk on lane 0, a merged feature branch
    /// on lane 1, an old side branch on lane 2. The lane numbers are exactly
    /// what GroveCore.layoutLanes produces for this parent structure
    /// (testFixtureGraphLanesMatchLayoutLanes keeps that honest).
    static func fixtureGraphNodes(now: Date) -> [CommitNode] {
        func at(hoursAgo: Double) -> Date { now.addingTimeInterval(-hoursAgo * 3_600) }
        return [
            CommitNode(hash: "a1", parents: ["a2", "b1"], author: "artem", date: at(hoursAgo: 2),
                       refs: ["HEAD -> dev", "origin/dev"], subject: "Merge media upload pipeline", lane: 0),
            CommitNode(hash: "b1", parents: ["b2"], author: "claude", date: at(hoursAgo: 5),
                       refs: ["feat/media-upload"], subject: "Add chunked upload retry", lane: 1),
            CommitNode(hash: "a2", parents: ["a3"], author: "artem", date: at(hoursAgo: 8),
                       refs: [], subject: "Fix session token refresh", lane: 0),
            CommitNode(hash: "b2", parents: ["a3"], author: "claude", date: at(hoursAgo: 26),
                       refs: [], subject: "Wire upload progress events", lane: 1),
            CommitNode(hash: "a3", parents: ["a4"], author: "artem", date: at(hoursAgo: 50),
                       refs: ["tag: v0.4.0"], subject: "Release 0.4.0", lane: 0),
            CommitNode(hash: "c1", parents: ["a4"], author: "artem", date: at(hoursAgo: 70),
                       refs: ["feat/folders-followup"], subject: "Folder share ACL checks", lane: 1),
            CommitNode(hash: "d1", parents: ["a4"], author: "claude", date: at(hoursAgo: 200),
                       refs: ["feat/live-tier-redis"], subject: "Redis live tier experiment", lane: 2),
            CommitNode(hash: "a4", parents: [], author: "artem", date: at(hoursAgo: 240),
                       refs: ["main"], subject: "Initial import", lane: 0),
        ]
    }

    // MARK: - Identity fixture (consumed by AccountsScreen in Task 22)

    /// Deterministic identities for accounts.png: "default" is logged in,
    /// every other account renders the not-logged-in row.
    static func fixtureIdentity(_ account: AccountConfig) -> AccountIdentity? {
        guard account.name == "default" else { return nil }
        return AccountIdentity(email: "artem@example.com",
                               organization: "Personal",
                               tier: "max_20x",
                               organizationRateLimitTier: "default_claude_max_20x")
    }

    // MARK: - Rendering

    @MainActor
    static func renderAll(into outDir: URL) throws -> Int {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        for scene in SnapshotScene.allCases {
            try writePNG(view(for: scene), size: scene.size,
                         to: outDir.appendingPathComponent(scene.fileName))
        }
        return SnapshotScene.allCases.count
    }

    /// Fresh fixture per scene with the scene's ROUTE applied. The route is
    /// set directly (NOT via open()) so no scan/refresh Task ever starts for
    /// the synthetic project path. SnapshotModeTests asserts the route per
    /// scene through this seam.
    @MainActor
    static func configuredState(for scene: SnapshotScene) -> AppState {
        let state = fixtureState()
        // The fixture always has exactly one project selected.
        let projectID = state.selectedProjectID!
        switch scene {
        case .projects:
            state.route = .projects
        case .charts:
            // The standalone Charts side window; fixture already carries usage data.
            state.route = .projects
        case .rootWorkspaces, .workspacesExpanded:
            state.route = .project(projectID)
        case .createSheet:
            state.createPrefill = CreatePrefill(name: "checkout-flow")
            state.route = .createWorkspace(projectID)
        case .graph:
            state.selectedTab = .graph
            state.route = .project(projectID)
        case .sessions:
            state.selectedTab = .sessions
            state.route = .project(projectID)
        case .accounts, .accountsUsage:
            // Both route to .accounts; the fixture already carries the usage
            // data (usageByAccount/snapshotsByAccount/tierOverride), so the
            // accounts-usage scene renders bars/cards/tables/breakdown.
            state.route = .accounts
        case .settings:
            state.route = .projectSettings(projectID)
        case .errorBanner:
            // Pins the RootView error banner styling (DesignRadius.field,
            // material strip). The message mentions cmux so the "Launch cmux"
            // affordance renders too.
            state.route = .projects
            state.actionError = "cmux unavailable: socket control mode blocks external clients"
        }
        return state
    }

    @MainActor
    static func view(for scene: SnapshotScene) -> AnyView {
        // The Charts side window renders its standalone content, NOT the main shell
        // (charts is no longer a tab in RootView).
        if scene == .charts {
            return AnyView(ChartsSideContent(state: configuredState(for: scene)))
        }
        let root = RootView(state: configuredState(for: scene))
        if scene == .workspacesExpanded {
            return AnyView(root.environment(\.snapshotExpandedWorkspaces, ["media-upload"]))
        }
        return AnyView(root)
    }

    /// Offscreen render at the scene's logical size, scale 2.
    /// CAVEAT: ImageRenderer has no window/backdrop, so .glassEffect-modified
    /// views render INVISIBLE offscreen — \.isSnapshotRender makes GlassCard
    /// fall back to a plain translucent card. Snapshots verify LAYOUT and
    /// CONTENT, never glass blur. The dark gradient stands in for the missing
    /// desktop/panel material.
    @MainActor
    static func writePNG<Content: View>(_ content: Content, size: CGSize, to url: URL) throws {
        let wrapped = ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.14),
                                    Color(red: 0.16, green: 0.13, blue: 0.20)],
                           startPoint: .top, endPoint: .bottom)
            content
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
        .environment(\.isSnapshotRender, true)
        // Identity from the fixture, NEVER from ~/.claude.json: offscreen
        // renders must not read the user's real Claude config.
        .environment(\.claudeIdentityProvider, { SnapshotMode.fixtureIdentity($0) })

        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else {
            throw SnapshotError.renderFailed(url.lastPathComponent)
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodeFailed(url.lastPathComponent)
        }
        try data.write(to: url)
    }
}
