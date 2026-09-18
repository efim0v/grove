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
        case rootWorkspaces = "root-workspaces"
        case workspacesExpanded = "workspaces-expanded"
        case createSheet = "create-sheet"
        case graph = "graph"
        case stats = "stats"
        case sessions = "sessions"
        case accounts = "accounts"
        case settings = "settings"
        case statsSettings = "stats-settings"
        case errorBanner = "error-banner"

        var fileName: String { rawValue + ".png" }

        /// Canvas size = the route's adaptive panel frame (RootView).
        /// error-banner adds vertical allowance on top of the projects frame
        /// because RootView stacks the banner ABOVE the routed screen.
        var size: CGSize {
            switch self {
            case .projects: return CGSize(width: 460, height: 520)
            case .rootWorkspaces, .workspacesExpanded, .graph, .stats, .sessions:
                return CGSize(width: 600, height: 540)
            case .createSheet: return CGSize(width: 540, height: 560)
            case .accounts: return CGSize(width: 560, height: 480)
            case .settings, .statsSettings: return CGSize(width: 560, height: 560)
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
            defaultAccount: "work",     // settings.png shows the account picker non-empty
            // One pre-excluded folder so stats-settings shows the excluded (dimmed,
            // disabled-descendant) state in the directory+file tree.
            statsIgnoredFolders: ["Snapshot"]
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

        // Statusline captures: deterministic per-session model/context/effort for
        // the Accounts scene's session cards.
        state.snapshotsByAccount = fixtureSnapshotsByAccount(now: now)

        // Code-stats fixture (Stage 5): a canned CodeStats + a short history so the
        // Stats tab renders the totals header, language bars/table, and the growth
        // chart's MANUAL (non-Charts) fallback offscreen. The `.task` scan never runs
        // in snapshot mode (routes are set directly), so these must be pre-seeded.
        state.codeStats = [project.id: fixtureCodeStats(now: now)]
        state.codeStatsHistory = [project.id: fixtureCodeStatsHistory(now: now)]
        state.repoStats = [project.id: fixtureRepoStats(now: now)]
        // Per-file list (Stage 5 final): the stats-settings page builds its
        // directory+file tree purely from this, so the tree renders offscreen.
        // One folder (Snapshot) is pre-excluded so the disabled/dimmed state shows.
        state.statsFiles = [project.id: fixtureStatFiles()]

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

    /// Most-recent statusline captures per account: the Accounts scene's session
    /// cards read model / context % / effort from these.
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
                                         head: "aaaa111", isMain: false,
                                         createdAt: day(12)),
                    meta: WorktreeMeta(baseBranch: "dev", forkPoint: "ffff000",
                                       forkDate: day(12), ahead: 14, behind: 2, dirtyCount: 8,
                                       lastCommitDate: day(0.04),
                                       lastCommitSubject: "wire upload progress events"),
                    scanError: nil),
                WorkspaceRepoState(
                    repo: server,
                    entry: WorktreeEntry(path: mpUmbrella + "/acme_server",
                                         branch: "feat/media-pipeline",
                                         head: "aaaa222", isMain: false,
                                         createdAt: day(12)),
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
                                         head: "bbbb111", isMain: false,
                                         createdAt: day(2)),
                    meta: WorktreeMeta(baseBranch: "feat/media-pipeline", forkPoint: "aaaa111",
                                       forkDate: day(2), ahead: 3, behind: 0, dirtyCount: 3,
                                       lastCommitDate: day(0.1),
                                       lastCommitSubject: "upload retry with backoff"),
                    scanError: nil),
                WorkspaceRepoState(
                    repo: server,
                    entry: WorktreeEntry(path: muUmbrella + "/acme_server",
                                         branch: "feat/media-upload",
                                         head: "bbbb222", isMain: false,
                                         createdAt: day(2)),
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
                                         head: "cccc111", isMain: false,
                                         createdAt: day(24)),
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

    // MARK: - Code-stats fixture (consumed by CodeStatsScreen in Stage 5)

    /// A canned multi-language tally so the Stats tab renders bars + the per-language
    /// table + the totals header. `byLanguage` is sorted DESC by code, like the real
    /// scanner; totals sum the languages so the code/data percentage is consistent.
    static func fixtureCodeStats(now: Date) -> CodeStats {
        let langs = [
            LanguageStats(language: "Swift", files: 142, code: 18_420, comment: 3_180, blank: 2_640, total: 24_240),
            LanguageStats(language: "TypeScript/JavaScript", files: 96, code: 11_900, comment: 1_540, blank: 1_810, total: 15_250),
            LanguageStats(language: "Python", files: 38, code: 4_310, comment: 920, blank: 760, total: 5_990),
            LanguageStats(language: "Shell", files: 14, code: 820, comment: 210, blank: 160, total: 1_190),
            LanguageStats(language: "Markdown", files: 22, code: 1_640, comment: 0, blank: 480, total: 2_120),
        ]
        let code = langs.reduce(0) { $0 + $1.code }
        let comment = langs.reduce(0) { $0 + $1.comment }
        let blank = langs.reduce(0) { $0 + $1.blank }
        let files = langs.reduce(0) { $0 + $1.files }
        return CodeStats(totalFiles: files, totalLines: code + comment + blank,
                         code: code, comment: comment, blank: blank,
                         byLanguage: langs, scannedAt: now, skippedBinary: 9)
    }

    /// A short rising line history (oldest first) so the growth chart's manual bar
    /// fallback draws a real rising series offscreen. Each step also carries that day's
    /// added/removed so the Totals delta-triangle and the bar-selection readout have
    /// real values in snapshots.
    static func fixtureCodeStatsHistory(now: Date) -> [CodeStatsPoint] {
        func day(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }
        let totals = [38_200, 39_100, 41_500, 44_900, 46_300, 48_790]
        var previous = 0
        return totals.enumerated().map { i, total in
            // Derive per-day added/removed from the cumulative step (a little churn so
            // "removed" is non-zero): the net matches the cumulative delta.
            let net = i == 0 ? total : total - previous
            previous = total
            let removed = i == 0 ? 0 : max(net / 4, 0)
            let added = net + removed
            // ~80% of each day's churn is code, ~20% data/prose (markdown), so the
            // honest Code/Data triangles have real, distinct values in snapshots.
            let codeAdded = Int(Double(added) * 0.8)
            let codeRemoved = Int(Double(removed) * 0.8)
            return CodeStatsPoint(date: day(Double(totals.count - 1 - i) * 6),
                                  totalLines: total,
                                  code: Int(Double(total) * 0.79), comment: Int(Double(total) * 0.10),
                                  blank: Int(Double(total) * 0.11),
                                  totalFiles: 280 + i * 6,
                                  dayAdded: added, dayRemoved: removed,
                                  codeAdded: codeAdded, codeRemoved: codeRemoved,
                                  dataAdded: added - codeAdded, dataRemoved: removed - codeRemoved)
        }
    }

    /// Per-repo breakdown for the Stats tab's per-repo blocks: two repos with their own
    /// branch, LOC, and a per-day history (oldest first) so each block's period delta
    /// recomputes client-side like the real scan output.
    static func fixtureRepoStats(now: Date) -> [RepoStats] {
        func day(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }
        // `dataFraction` of each day's churn is data/prose; the rest is code. media-pipeline
        // is code-heavy (0), media-upload is mixed (some markdown/json churn).
        func history(_ steps: [(net: Int, added: Int, removed: Int)], dataFraction: Double) -> [RepoHistoryPoint] {
            var cumulative = 0
            return steps.enumerated().map { i, s in
                cumulative += s.net
                let dataAdded = Int(Double(s.added) * dataFraction)
                let dataRemoved = Int(Double(s.removed) * dataFraction)
                return RepoHistoryPoint(date: day(Double(steps.count - 1 - i) * 6),
                                        netLines: cumulative,
                                        dayAdded: s.added, dayRemoved: s.removed,
                                        codeAdded: s.added - dataAdded, codeRemoved: s.removed - dataRemoved,
                                        dataAdded: dataAdded, dataRemoved: dataRemoved)
            }
        }
        func stats(files: Int, lines: Int, langs: [LanguageStats]) -> CodeStats {
            CodeStats(totalFiles: files, totalLines: lines, code: Int(Double(lines) * 0.82),
                      comment: Int(Double(lines) * 0.09), blank: Int(Double(lines) * 0.09),
                      byLanguage: langs, scannedAt: now, skippedBinary: 0)
        }
        func lang(_ name: String, files: Int, code: Int, comment: Int = 0, blank: Int = 0) -> LanguageStats {
            LanguageStats(language: name, files: files, code: code, comment: comment, blank: blank,
                          total: code + comment + blank)
        }
        return [
            RepoStats(repoPath: "/Users/demo/Workspaces/acme.shop/media-pipeline",
                      repoName: "media-pipeline",
                      defaultBranch: "main",
                      // A per-repo language split so a snapshot scoped to this repo (via the
                      // shared repo selector) shows real Languages bars, not an empty card.
                      stats: stats(files: 184, lines: 31_400, langs: [
                        lang("Swift", files: 120, code: 18_400, comment: 2_100, blank: 2_400),
                        lang("Python", files: 44, code: 4_600, comment: 600, blank: 700),
                        lang("Markdown", files: 20, code: 0, comment: 0, blank: 100),
                      ]),
                      history: history([(0, 0, 0), (640, 700, 60), (1_180, 1_300, 120),
                                        (1_540, 1_720, 180), (820, 990, 170)], dataFraction: 0),
                      delta: RepoDelta(added: 4_010, removed: 530, filesChanged: 22)),
            RepoStats(repoPath: "/Users/demo/Workspaces/acme.shop/media-upload",
                      repoName: "media-upload",
                      defaultBranch: "develop",
                      stats: stats(files: 96, lines: 17_390, langs: [
                        lang("TypeScript/JavaScript", files: 60, code: 9_800, comment: 900, blank: 1_300),
                        lang("JSON", files: 18, code: 2_200, comment: 0, blank: 0),
                        lang("CSS", files: 18, code: 1_900, comment: 100, blank: 290),
                      ]),
                      history: history([(0, 0, 0), (310, 360, 50), (-120, 40, 160),
                                        (540, 620, 80), (290, 330, 40)], dataFraction: 0.25),
                      delta: RepoDelta(added: 1_350, removed: 330, filesChanged: 11)),
        ]
    }

    /// A canned project-relative per-file list so the stats-settings page renders its
    /// directory+file tree offscreen: a couple of nested source folders (so folder
    /// rows show summed LOC + counts), a data/prose file (Markdown → neutral tint),
    /// and one pre-excluded folder (see `fixtureState` setting `statsIgnoredFolders`).
    /// The excluded folder's file carries `isExcluded` exactly as a live scan emits it,
    /// so the Snapshot folder stays in the tree with its (enabled) re-include toggle.
    static func fixtureStatFiles() -> [StatFileEntry] {
        [
            StatFileEntry(path: "Sources/GroveCore/Services/GitStatsService.swift",
                          lines: 520, language: "Swift", isDataProse: false),
            StatFileEntry(path: "Sources/GroveCore/Services/GitService.swift",
                          lines: 310, language: "Swift", isDataProse: false),
            StatFileEntry(path: "Sources/GroveAppKit/Views/RootView.swift",
                          lines: 153, language: "Swift", isDataProse: false),
            StatFileEntry(path: "Sources/GroveAppKit/Views/StatsSettingsScreen.swift",
                          lines: 210, language: "Swift", isDataProse: false),
            // Pre-excluded (its folder is in statsIgnoredFolders), so it carries
            // isExcluded — exactly what a live scan emits for an excluded folder,
            // keeping the Snapshot folder + its re-include toggle in the tree.
            StatFileEntry(path: "Snapshot/SnapshotMode.swift",
                          lines: 780, language: "Swift", isDataProse: false,
                          isExcluded: true),
            StatFileEntry(path: "README.md", lines: 48, language: "Markdown", isDataProse: true),
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
        case .rootWorkspaces, .workspacesExpanded:
            state.route = .project(projectID)
        case .createSheet:
            state.createPrefill = CreatePrefill(name: "checkout-flow")
            state.route = .createWorkspace(projectID)
        case .graph:
            state.selectedTab = .graph
            state.route = .project(projectID)
        case .stats:
            // The fixture pre-seeds codeStats + codeStatsHistory, so the Stats tab
            // renders the totals header, language bars/table, and the growth chart's
            // manual (non-Charts) fallback offscreen.
            state.selectedTab = .stats
            state.route = .project(projectID)
        case .sessions:
            state.selectedTab = .sessions
            state.route = .project(projectID)
        case .accounts:
            state.route = .accounts
        case .settings:
            state.route = .projectSettings(projectID)
        case .statsSettings:
            // The fixture pre-seeds statsFiles + one excluded folder, so the
            // directory+file tree (summed folder LOC, file tints, the dimmed
            // excluded folder) renders offscreen from injected data.
            state.route = .statsSettings(projectID)
        case .errorBanner:
            // Pins the RootView error banner styling (DesignRadius.field,
            // material strip). The message mentions cmux so the "Launch cmux"
            // affordance renders too.
            state.route = .projects
            state.actionError = "cmux unavailable: socket control mode blocks external clients"
        }
        return state
    }

    /// Renders the heavier screens once offscreen so the FIRST real navigation
    /// isn't paying SwiftUI's cold body-build + layout cost (the "first run is
    /// slow, then snappy" effect). Uses isolated fixture state (never ~/.claude)
    /// with isSnapshotRender, and discards the rendered image.
    @MainActor
    static func prewarm() {
        for scene in [SnapshotScene.rootWorkspaces, .settings] {
            let content = view(for: scene)
                .environment(\.isSnapshotRender, true)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            _ = renderer.cgImage
        }
    }

    @MainActor
    static func view(for scene: SnapshotScene) -> AnyView {
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
