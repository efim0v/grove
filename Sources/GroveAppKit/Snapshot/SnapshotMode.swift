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
        case sessions = "sessions"
        case accounts = "accounts"
        case settings = "settings"
        case errorBanner = "error-banner"

        var fileName: String { rawValue + ".png" }

        /// Canvas size = the route's adaptive panel frame (RootView).
        /// error-banner adds vertical allowance on top of the projects frame
        /// because RootView stacks the banner ABOVE the routed screen.
        var size: CGSize {
            switch self {
            case .projects: return CGSize(width: 420, height: 440)
            case .rootWorkspaces, .workspacesExpanded, .graph, .sessions:
                return CGSize(width: 760, height: 540)
            case .createSheet: return CGSize(width: 540, height: 560)
            case .accounts: return CGSize(width: 560, height: 480)
            case .settings: return CGSize(width: 560, height: 560)
            case .errorBanner: return CGSize(width: 420, height: 504)
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
        return state
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
        case .accounts:
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
