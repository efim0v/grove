import AppKit
import SwiftUI
import XCTest
import GroveCore
@testable import GroveAppKit

/// README screenshots for Grove, rendered offscreen from a FICTIONAL project
/// ("acme-shop") — no git, no disk scan, no real config, nothing from `~/.claude`.
///
/// Skipped unless `DEMO_SCREENSHOTS_DIR` is set, so a plain `swift test` never
/// writes files:
///
///     DEMO_SCREENSHOTS_DIR="$PWD/docs/screenshots" swift test --filter DemoScreenshotTests
///
/// Same ImageRenderer path (and the same caveats) as `GroveApp --snapshot`, see
/// docs/snapshot-testing.md: no Liquid Glass, a stand-in gradient for the desktop.
final class DemoScreenshotTests: XCTestCase {

    /// Plain (not `@MainActor`) so it is called synchronously on the main thread, the
    /// way `GroveApp --snapshot` renders.
    func testRenderGroveDemoScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["DEMO_SCREENSHOTS_DIR"], !dir.isEmpty else {
            throw XCTSkip("set DEMO_SCREENSHOTS_DIR to render the README screenshots")
        }
        try MainActor.assumeIsolated { try renderAll(into: dir) }
    }

    @MainActor
    private func renderAll(into dir: String) throws {
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        func state(_ configure: (AppState, UUID) -> Void) -> AppState {
            let s = DemoFixture.state()
            configure(s, DemoFixture.shopID)
            return s
        }

        // (1) Main panel: the project list with each project's recent sessions.
        try render(RootView(state: state { s, _ in s.route = .projects }),
                   width: 460, to: out.appendingPathComponent("grove-projects.png"))

        // (1b) A project's workspaces, one expanded (repos, sessions, actions).
        try render(RootView(state: state { s, id in s.route = .project(id) })
                    .environment(\.snapshotExpandedWorkspaces, ["checkout-redesign"]),
                   width: 600, to: out.appendingPathComponent("grove-workspaces.png"))

        // (2) Branch graph.
        try render(RootView(state: state { s, id in s.selectedTab = .graph; s.route = .project(id) }),
                   width: 600, to: out.appendingPathComponent("grove-branch-graph.png"))

        // (3) Code statistics.
        let statsState = state { s, id in s.selectedTab = .stats; s.route = .project(id) }
        try render(RootView(state: statsState), width: 600,
                   to: out.appendingPathComponent("grove-code-stats.png"), settling: statsState)

        // (4) Workspace creation form.
        try render(RootView(state: state { s, id in
                        s.createPrefill = CreatePrefill(name: "loyalty-points")
                        s.route = .createWorkspace(id)
                    }),
                   width: 540, to: out.appendingPathComponent("grove-new-workspace.png"))

        // (5) Sessions across accounts: the Claude tab (every row carries the
        // migrate-to-account control) and the Accounts screen.
        try render(RootView(state: state { s, id in s.selectedTab = .sessions; s.route = .project(id) }),
                   width: 600, to: out.appendingPathComponent("grove-sessions.png"))
        try render(AccountsScreen(state: state { s, _ in s.route = .accounts }).tint(Palette.primary),
                   width: 560, to: out.appendingPathComponent("grove-accounts.png"))

        // (6) Project settings. Rendered as the screen itself, not through RootView:
        // RootView pins this route to 560 pt and scrolls, and a ScrollView does not
        // render offscreen.
        try render(ProjectSettingsScreen(state: state { s, id in s.route = .projectSettings(id) },
                                         projectID: DemoFixture.shopID).tint(Palette.primary),
                   width: 560, to: out.appendingPathComponent("grove-project-settings.png"))
    }

    /// The view at `width` and its own natural height, @2x, on the stand-in backdrop,
    /// clipped to the panel's rounded outline (transparent corners).
    ///
    /// `settling`: under XCTest (unlike `GroveApp --snapshot`) a view's `.task` does start
    /// during the render. The Stats tab's task begins a code scan — of the fixture's
    /// non-existent project path, writing only to the temp `statsStoreDirOverride` — and
    /// draws a spinner meanwhile. So: render once, let that scan finish, put the fixture
    /// numbers back, and render the SAME renderer again (same view identity, so the task
    /// does not restart).
    @MainActor
    private func render<V: View>(_ view: V, width: CGFloat, to url: URL, settling state: AppState? = nil) throws {
        let shape = RoundedRectangle(cornerRadius: DesignRadius.panel, style: .continuous)
        let wrapped = view
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.14),
                                                Color(red: 0.16, green: 0.13, blue: 0.20)],
                                       startPoint: .top, endPoint: .bottom))
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.10)))
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotRender, true)
            .environment(\.claudeIdentityProvider, { DemoFixture.identity($0) })
        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = 2
        if let state {
            _ = renderer.cgImage
            let deadline = Date().addingTimeInterval(10)
            while state.isStatsScanning, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertFalse(state.isStatsScanning, "the stats scan of the fixture path did not settle")
            DemoFixture.seedStats(state, now: Date())
        }
        let image = try XCTUnwrap(renderer.cgImage, "no image for \(url.lastPathComponent)")
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: url)
        print("demo screenshot: \(url.path) \(image.width)x\(image.height)")
    }
}

/// A fictional multi-repo product. Every name here is invented.
@MainActor
enum DemoFixture {
    static let shopID = UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!
    static let notesID = UUID(uuidString: "D0000000-0000-0000-0000-000000000002")!
    static let projectPath = "/Users/demo/Code/acme-shop"
    static let workspacesRoot = "/Users/demo/Workspaces/acme-shop"

    static func identity(_ account: AccountConfig) -> AccountIdentity? {
        switch account.name {
        case "personal":
            return AccountIdentity(email: "alex@example.com", organization: "Personal",
                                   tier: "max_5x", organizationRateLimitTier: "default_claude_max_5x")
        case "work":
            return AccountIdentity(email: "alex.morgan@example.com", organization: "Acme Shop",
                                   tier: "max_20x", organizationRateLimitTier: "default_claude_max_20x")
        case "team":
            return AccountIdentity(email: "platform-team@example.com", organization: "Acme Platform",
                                   tier: "max_20x", organizationRateLimitTier: "default_claude_max_20x")
        default:
            return nil
        }
    }

    static func state() -> AppState {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-demo-\(UUID().uuidString)/config.json")
        let state = AppState(configStore: ConfigStore(url: url))
        // A scan started by the Stats tab must never write under the real
        // ~/Library/Application Support/Grove/stats.
        state.statsStoreDirOverride = url.deletingLastPathComponent().appendingPathComponent("stats").path
        let now = Date()

        let shop = ProjectConfig(id: shopID, name: "acme-shop", path: projectPath,
                                 workspacesRoot: workspacesRoot,
                                 baseBranchOverrides: ["api-server": "develop", "server-config": "production",
                                                       "web-client": "develop"],
                                 defaultAccount: "work")
        let notes = ProjectConfig(id: notesID, name: "field-notes", path: "/Users/demo/Code/field-notes",
                                  workspacesRoot: "/Users/demo/Workspaces/field-notes")
        state.config = GroveConfig(
            version: 1,
            workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [shop, notes],
            accounts: [
                AccountConfig(name: "personal", configDir: "~/.claude"),
                AccountConfig(name: "work", configDir: "~/.claude-accounts/work", sharedStore: true),
                AccountConfig(name: "team", configDir: "~/.claude-accounts/team", sharedStore: true),
            ])
        state.snapshots = [shopID: shopSnapshot(project: shop, now: now),
                           notesID: notesSnapshot(project: notes, now: now)]
        state.selectedProjectID = shopID
        state.branchesByRepo = [
            projectPath + "/admin-panel": ["feat/search-v2", "main"],
            projectPath + "/api-server": ["develop", "feat/checkout-redesign", "feat/search-v2",
                                          "fix/payment-webhooks", "main"],
            projectPath + "/landing": ["feat/landing-autumn-sale", "main"],
            projectPath + "/server-config": ["fix/payment-webhooks", "production", "staging"],
            projectPath + "/web-client": ["develop", "feat/checkout-promo-codes", "feat/checkout-redesign",
                                          "feat/search-v2", "main"],
        ]
        state.graphRepoPath = projectPath + "/web-client"
        state.graphNodes = graphNodes(now: now)
        state.snapshotsByAccount = usageByAccount(now: now)
        seedStats(state, now: now)
        state.recentSessionsByProject = [
            shopID: [
                ProjectSessionRow(sessionId: "s-co-1", title: "Checkout: address step validation",
                                  cwd: workspacesRoot + "/checkout-redesign", location: "checkout-redesign",
                                  accountName: "work", lastActivity: now.addingTimeInterval(-240),
                                  status: .running, cmuxWorkspaceId: "ws-201"),
                ProjectSessionRow(sessionId: "s-pw-1", title: "Retry failed webhook deliveries",
                                  cwd: workspacesRoot + "/fix-payment-webhooks", location: "fix-payment-webhooks",
                                  accountName: "team", lastActivity: now.addingTimeInterval(-660),
                                  status: .waiting, cmuxWorkspaceId: nil),
            ],
            notesID: [
                ProjectSessionRow(sessionId: "s-fn-1", title: "Offline sync conflict resolution",
                                  cwd: "/Users/demo/Workspaces/field-notes/offline-sync", location: "offline-sync",
                                  accountName: "personal", lastActivity: now.addingTimeInterval(-5_400),
                                  status: .waiting, cmuxWorkspaceId: nil),
            ],
        ]
        return state
    }

    static func seedStats(_ state: AppState, now: Date) {
        state.codeStats = [shopID: codeStats(now: now)]
        state.codeStatsHistory = [shopID: codeStatsHistory(now: now)]
        state.repoStats = [shopID: repoStats(now: now)]
    }

    // MARK: - Workspaces

    private static func repo(_ name: String) -> RepoInfo {
        RepoInfo(path: projectPath + "/" + name, dirName: name)
    }

    private static func worktree(_ workspace: String, _ repoName: String, branch: String, base: String,
                                 head: String, created: Date, ahead: Int, behind: Int, dirty: Int,
                                 lastCommit: Date, subject: String) -> WorkspaceRepoState {
        WorkspaceRepoState(
            repo: repo(repoName),
            entry: WorktreeEntry(path: workspacesRoot + "/" + workspace + "/" + repoName, branch: branch,
                                 head: head, isMain: false, createdAt: created),
            meta: WorktreeMeta(baseBranch: base, forkPoint: "f" + head, forkDate: created,
                               ahead: ahead, behind: behind, dirtyCount: dirty,
                               lastCommitDate: lastCommit, lastCommitSubject: subject),
            scanError: nil)
    }

    static func shopSnapshot(project: ProjectConfig, now: Date) -> ProjectSnapshot {
        func day(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }
        func minutes(_ n: Double) -> Date { now.addingTimeInterval(-n * 60) }

        let co = workspacesRoot + "/checkout-redesign"
        let checkout = FeatureWorkspace(
            name: "checkout-redesign", umbrellaPath: co,
            repos: [
                worktree("checkout-redesign", "web-client", branch: "feat/checkout-redesign", base: "develop",
                         head: "a11c0de", created: day(5), ahead: 18, behind: 2, dirty: 6,
                         lastCommit: minutes(40), subject: "address step: inline validation"),
                worktree("checkout-redesign", "api-server", branch: "feat/checkout-redesign", base: "develop",
                         head: "a22c0de", created: day(5), ahead: 7, behind: 0, dirty: 2,
                         lastCommit: day(0.3), subject: "orders: idempotent submit"),
            ],
            parentName: nil,
            sessions: [
                ClaudeSession(id: "s-co-1", cwd: co, title: "Checkout: address step validation",
                              lastActivity: minutes(4), accountName: "work", gitBranch: "feat/checkout-redesign"),
                ClaudeSession(id: "s-co-2", cwd: co, title: "Order summary component",
                              lastActivity: day(1), accountName: "personal", gitBranch: "feat/checkout-redesign"),
            ],
            liveProcesses: [
                LiveProcess(pid: 5101, sessionId: "s-co-1", cwd: co, status: "busy", accountName: "work",
                            startedAt: minutes(52)),
            ],
            cmuxWorkspaces: [CmuxWorkspace(id: "ws-201", title: "checkout-redesign", currentDirectory: co)])

        let pc = workspacesRoot + "/checkout-promo-codes"
        let promo = FeatureWorkspace(
            name: "checkout-promo-codes", umbrellaPath: pc,
            repos: [
                worktree("checkout-promo-codes", "web-client", branch: "feat/checkout-promo-codes",
                         base: "feat/checkout-redesign", head: "b11c0de", created: day(1), ahead: 4, behind: 0,
                         dirty: 3, lastCommit: day(0.2), subject: "promo field + error states"),
                worktree("checkout-promo-codes", "api-server", branch: "feat/checkout-promo-codes",
                         base: "feat/checkout-redesign", head: "b22c0de", created: day(1), ahead: 2, behind: 0,
                         dirty: 0, lastCommit: day(0.6), subject: "POST /cart/promo"),
            ],
            parentName: "checkout-redesign",
            sessions: [
                ClaudeSession(id: "s-pc-1", cwd: pc, title: "Promo code endpoint and tests",
                              lastActivity: day(0.25), accountName: "work", gitBranch: "feat/checkout-promo-codes"),
            ],
            liveProcesses: [], cmuxWorkspaces: [])

        let pw = workspacesRoot + "/fix-payment-webhooks"
        let webhooks = FeatureWorkspace(
            name: "fix-payment-webhooks", umbrellaPath: pw,
            repos: [
                worktree("fix-payment-webhooks", "api-server", branch: "fix/payment-webhooks", base: "develop",
                         head: "c11c0de", created: day(2), ahead: 5, behind: 1, dirty: 1,
                         lastCommit: day(0.1), subject: "verify signature before parsing"),
                worktree("fix-payment-webhooks", "server-config", branch: "fix/payment-webhooks",
                         base: "production", head: "c22c0de", created: day(2), ahead: 1, behind: 0, dirty: 0,
                         lastCommit: day(1.2), subject: "raise webhook worker timeout"),
            ],
            parentName: nil,
            sessions: [
                ClaudeSession(id: "s-pw-1", cwd: pw, title: "Retry failed webhook deliveries",
                              lastActivity: minutes(11), accountName: "team", gitBranch: "fix/payment-webhooks"),
            ],
            liveProcesses: [
                LiveProcess(pid: 5202, sessionId: "s-pw-1", cwd: pw, status: "waiting", accountName: "team",
                            startedAt: minutes(38)),
            ],
            cmuxWorkspaces: [])

        let sv = workspacesRoot + "/search-v2"
        let search = FeatureWorkspace(
            name: "search-v2", umbrellaPath: sv,
            repos: [
                worktree("search-v2", "web-client", branch: "feat/search-v2", base: "develop",
                         head: "d11c0de", created: day(13), ahead: 31, behind: 9, dirty: 0,
                         lastCommit: day(3), subject: "facet chips + url state"),
                worktree("search-v2", "api-server", branch: "feat/search-v2", base: "develop",
                         head: "d22c0de", created: day(13), ahead: 22, behind: 4, dirty: 0,
                         lastCommit: day(4), subject: "typo-tolerant query parser"),
                worktree("search-v2", "admin-panel", branch: "feat/search-v2", base: "main",
                         head: "d33c0de", created: day(11), ahead: 6, behind: 0, dirty: 0,
                         lastCommit: day(6), subject: "synonyms editor"),
            ],
            parentName: nil,
            sessions: [
                ClaudeSession(id: "s-sv-1", cwd: sv, title: "Search relevance tuning",
                              lastActivity: day(3), accountName: "team", gitBranch: "feat/search-v2"),
                ClaudeSession(id: "s-sv-2", cwd: sv, title: "Index rebuild job",
                              lastActivity: day(5), accountName: "work", gitBranch: "feat/search-v2"),
            ],
            liveProcesses: [], cmuxWorkspaces: [])

        let la = workspacesRoot + "/landing-autumn-sale"
        let landing = FeatureWorkspace(
            name: "landing-autumn-sale", umbrellaPath: la,
            repos: [
                worktree("landing-autumn-sale", "landing", branch: "feat/landing-autumn-sale", base: "main",
                         head: "e11c0de", created: day(26), ahead: 12, behind: 15, dirty: 0,
                         lastCommit: day(22), subject: "hero banner + countdown"),
            ],
            parentName: nil,
            sessions: [
                ClaudeSession(id: "s-la-1", cwd: la, title: "Autumn sale hero copy",
                              lastActivity: day(22), accountName: "personal", gitBranch: "feat/landing-autumn-sale"),
            ],
            liveProcesses: [], cmuxWorkspaces: [])

        let loosePath = repo("admin-panel").path + "/.worktrees/audit-log"
        let loose = LooseWorktree(
            repo: repo("admin-panel"),
            entry: WorktreeEntry(path: loosePath, branch: "spike/audit-log", head: "f11c0de", isMain: false),
            meta: WorktreeMeta(baseBranch: "main", forkPoint: "ff11c0de", forkDate: day(9), ahead: 3, behind: 1,
                               dirtyCount: 0, lastCommitDate: day(8), lastCommitSubject: "audit log table"),
            sessions: [
                ClaudeSession(id: "s-al-1", cwd: loosePath, title: "Audit log spike",
                              lastActivity: day(8), accountName: "personal", gitBranch: "spike/audit-log"),
            ],
            liveProcesses: [], cmuxWorkspaces: [])

        return ProjectSnapshot(
            project: project,
            repos: ["admin-panel", "api-server", "landing", "server-config", "web-client"].map(repo),
            workspaces: [promo, checkout, webhooks, landing, search].sorted { $0.name < $1.name },
            loose: [loose],
            errors: [])
    }

    static func notesSnapshot(project: ProjectConfig, now: Date) -> ProjectSnapshot {
        let root = "/Users/demo/Workspaces/field-notes"
        func notesRepo(_ name: String) -> RepoInfo { RepoInfo(path: project.path + "/" + name, dirName: name) }
        let ws = FeatureWorkspace(
            name: "offline-sync", umbrellaPath: root + "/offline-sync",
            repos: [
                WorkspaceRepoState(
                    repo: notesRepo("notes-ios"),
                    entry: WorktreeEntry(path: root + "/offline-sync/notes-ios", branch: "feat/offline-sync",
                                         head: "9a1c0de", isMain: false,
                                         createdAt: now.addingTimeInterval(-3 * 86_400)),
                    meta: WorktreeMeta(baseBranch: "main", forkPoint: "f9a1c0de",
                                       forkDate: now.addingTimeInterval(-3 * 86_400), ahead: 6, behind: 0,
                                       dirtyCount: 2, lastCommitDate: now.addingTimeInterval(-5_400),
                                       lastCommitSubject: "merge policy: last-writer-wins per field"),
                    scanError: nil),
            ],
            parentName: nil,
            sessions: [
                ClaudeSession(id: "s-fn-1", cwd: root + "/offline-sync", title: "Offline sync conflict resolution",
                              lastActivity: now.addingTimeInterval(-5_400), accountName: "personal",
                              gitBranch: "feat/offline-sync"),
            ],
            liveProcesses: [
                LiveProcess(pid: 5303, sessionId: "s-fn-1", cwd: root + "/offline-sync", status: "waiting",
                            accountName: "personal", startedAt: now.addingTimeInterval(-7_200)),
            ],
            cmuxWorkspaces: [])
        return ProjectSnapshot(project: project, repos: [notesRepo("notes-ios"), notesRepo("notes-sync")],
                               workspaces: [ws], loose: [], errors: [])
    }

    // MARK: - Graph

    /// Topology only; the lanes come from the real `layoutLanes`.
    static func graphNodes(now: Date) -> [CommitNode] {
        func at(_ hoursAgo: Double) -> Date { now.addingTimeInterval(-hoursAgo * 3_600) }
        let raw = [
            RawCommit(hash: "p2", parents: ["p1"], author: "sam", date: at(1),
                      refs: ["feat/checkout-promo-codes"], subject: "Promo field + error states"),
            RawCommit(hash: "c4", parents: ["c3"], author: "sam", date: at(2),
                      refs: ["HEAD -> feat/checkout-redesign"], subject: "Address step: inline validation"),
            RawCommit(hash: "p1", parents: ["c3"], author: "alex", date: at(5),
                      refs: [], subject: "Promo code input scaffold"),
            RawCommit(hash: "m3", parents: ["m2", "w2"], author: "alex", date: at(7),
                      refs: ["develop", "origin/develop"], subject: "Merge fix/cart-badge-count"),
            RawCommit(hash: "c3", parents: ["c2"], author: "sam", date: at(9),
                      refs: [], subject: "Order summary: tax and shipping rows"),
            RawCommit(hash: "w2", parents: ["w1"], author: "sam", date: at(20),
                      refs: [], subject: "Cart badge counts line items, not quantity"),
            RawCommit(hash: "c2", parents: ["c1"], author: "alex", date: at(26),
                      refs: [], subject: "Checkout stepper layout"),
            RawCommit(hash: "m2", parents: ["m1"], author: "alex", date: at(30),
                      refs: ["tag: v2.14.0"], subject: "Release 2.14.0"),
            RawCommit(hash: "w1", parents: ["m1"], author: "sam", date: at(34),
                      refs: [], subject: "Reproduce stale badge after remove"),
            RawCommit(hash: "c1", parents: ["m1"], author: "alex", date: at(50),
                      refs: [], subject: "Extract checkout routes"),
            RawCommit(hash: "s2", parents: ["s1"], author: "sam", date: at(72),
                      refs: ["feat/search-v2"], subject: "Facet chips + URL state"),
            RawCommit(hash: "m1", parents: ["m0"], author: "alex", date: at(96),
                      refs: [], subject: "Upgrade router, drop legacy guards"),
            RawCommit(hash: "s1", parents: ["m0"], author: "sam", date: at(150),
                      refs: [], subject: "Search results page skeleton"),
            RawCommit(hash: "m0", parents: [], author: "alex", date: at(240),
                      refs: ["main", "tag: v2.13.0"], subject: "Release 2.13.0"),
        ]
        return layoutLanes(raw)
    }

    // MARK: - Usage captures (model / context per session on the Accounts screen)

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func usageByAccount(now: Date) -> [String: [UsageSnapshot]] {
        func reset(_ seconds: TimeInterval) -> String { iso.string(from: now.addingTimeInterval(seconds)) }
        func snap(_ account: String, _ session: String, workspace: String, ago: TimeInterval, modelId: String,
                  model: String, effort: String, context: Double, tokens: Int, cost: Double,
                  five: Double, fiveReset: TimeInterval, week: Double, weekReset: TimeInterval) -> UsageSnapshot {
            UsageSnapshot(accountName: account, sessionId: session, capturedAt: now.addingTimeInterval(-ago),
                          cwd: workspacesRoot + "/" + workspace, modelId: modelId, modelDisplayName: model,
                          effort: effort, contextUsedPercentage: context, totalInputTokens: tokens,
                          totalCostUSD: cost,
                          fiveHour: CapturedWindow(usedPercentage: five, resetsAt: reset(fiveReset)),
                          sevenDay: CapturedWindow(usedPercentage: week, resetsAt: reset(weekReset)),
                          sevenDaySonnet: nil)
        }
        return [
            "work": [snap("work", "s-co-1", workspace: "checkout-redesign", ago: 240,
                          modelId: "claude-opus-4-8", model: "Opus 4.8", effort: "high", context: 47,
                          tokens: 212_400, cost: 7.18, five: 64, fiveReset: 1.4 * 3_600,
                          week: 41, weekReset: 3.2 * 86_400)],
            "team": [snap("team", "s-pw-1", workspace: "fix-payment-webhooks", ago: 660,
                          modelId: "claude-sonnet-4-6", model: "Sonnet 4.6", effort: "medium", context: 23,
                          tokens: 88_900, cost: 1.42, five: 22, fiveReset: 3.6 * 3_600,
                          week: 78, weekReset: 1.1 * 86_400)],
            "personal": [snap("personal", "s-co-2", workspace: "checkout-redesign", ago: 86_400,
                              modelId: "claude-sonnet-4-6", model: "Sonnet 4.6", effort: "medium", context: 61,
                              tokens: 143_000, cost: 2.05, five: 8, fiveReset: 4.5 * 3_600,
                              week: 19, weekReset: 5.4 * 86_400)],
        ]
    }

    // MARK: - Code statistics

    private static func lang(_ name: String, files: Int, code: Int, comment: Int, blank: Int) -> LanguageStats {
        LanguageStats(language: name, files: files, code: code, comment: comment, blank: blank,
                      total: code + comment + blank)
    }

    private static func stats(_ langs: [LanguageStats], now: Date, binary: Int = 0) -> CodeStats {
        let code = langs.reduce(0) { $0 + $1.code }
        let comment = langs.reduce(0) { $0 + $1.comment }
        let blank = langs.reduce(0) { $0 + $1.blank }
        return CodeStats(totalFiles: langs.reduce(0) { $0 + $1.files }, totalLines: code + comment + blank,
                         code: code, comment: comment, blank: blank,
                         byLanguage: langs.sorted { $0.code > $1.code }, scannedAt: now, skippedBinary: binary)
    }

    /// Per-repo language splits; the project totals are their sum.
    private static let repoLanguages: [(name: String, branch: String, langs: [LanguageStats])] = [
        ("web-client", "develop", [
            lang("TypeScript/JavaScript", files: 412, code: 38_600, comment: 3_100, blank: 5_200),
            lang("CSS", files: 96, code: 7_400, comment: 300, blank: 1_100),
            lang("JSON", files: 31, code: 2_900, comment: 0, blank: 0),
        ]),
        ("api-server", "develop", [
            lang("Python", files: 268, code: 29_800, comment: 4_600, blank: 5_900),
            lang("SQL", files: 74, code: 4_100, comment: 500, blank: 600),
            lang("YAML", files: 22, code: 1_300, comment: 100, blank: 100),
        ]),
        ("admin-panel", "main", [
            lang("TypeScript/JavaScript", files: 148, code: 12_700, comment: 900, blank: 1_800),
            lang("CSS", files: 28, code: 1_900, comment: 100, blank: 300),
        ]),
        ("landing", "main", [
            lang("HTML", files: 24, code: 3_200, comment: 100, blank: 400),
            lang("CSS", files: 18, code: 2_600, comment: 100, blank: 400),
            lang("Markdown", files: 12, code: 900, comment: 0, blank: 300),
        ]),
        ("server-config", "production", [
            lang("YAML", files: 64, code: 3_800, comment: 400, blank: 300),
            lang("Shell", files: 27, code: 1_500, comment: 300, blank: 250),
        ]),
    ]

    static func codeStats(now: Date) -> CodeStats {
        var merged: [String: LanguageStats] = [:]
        for l in repoLanguages.flatMap(\.langs) {
            let m = merged[l.language]
            merged[l.language] = lang(l.language, files: (m?.files ?? 0) + l.files, code: (m?.code ?? 0) + l.code,
                                      comment: (m?.comment ?? 0) + l.comment, blank: (m?.blank ?? 0) + l.blank)
        }
        return stats(Array(merged.values), now: now, binary: 46)
    }

    /// A deterministic "busy month": weekdays carry most of the churn, weekends little.
    private static func dailyChurn(days: Int, seed: Int, scale: Int) -> [(added: Int, removed: Int)] {
        (0..<days).map { i in
            let wave = abs((i * 37 + seed * 11) % 17 - 6) + (i * 7 + seed) % 5
            let weekend = (i + seed) % 7 >= 5
            let added = weekend ? scale / 6 * (wave % 3) : scale * (2 + wave) / 4
            return (added, added / (3 + (i + seed) % 4))
        }
    }

    static func repoStats(now: Date) -> [RepoStats] {
        let days = 160
        let start = Calendar(identifier: .gregorian).startOfDay(for: now)
        return repoLanguages.enumerated().map { index, entry in
            let s = stats(entry.langs, now: now)
            let scale = max(40, s.totalLines / 170)
            let dataFraction = entry.name == "server-config" ? 0.7 : entry.name == "landing" ? 0.3 : 0.08
            let churn = dailyChurn(days: days, seed: index * 3 + 1, scale: scale)
            let net = churn.reduce(0) { $0 + $1.added - $1.removed }
            var cumulative = s.totalLines - net
            let history = churn.enumerated().map { i, c -> RepoHistoryPoint in
                cumulative += c.added - c.removed
                let dataAdded = Int(Double(c.added) * dataFraction)
                let dataRemoved = Int(Double(c.removed) * dataFraction)
                return RepoHistoryPoint(date: start.addingTimeInterval(-Double(days - 1 - i) * 86_400),
                                        netLines: cumulative, dayAdded: c.added, dayRemoved: c.removed,
                                        codeAdded: c.added - dataAdded, codeRemoved: c.removed - dataRemoved,
                                        dataAdded: dataAdded, dataRemoved: dataRemoved)
            }
            let window = churn.suffix(30)
            return RepoStats(repoPath: projectPath + "/" + entry.name, repoName: entry.name,
                             defaultBranch: entry.branch, stats: s, history: history,
                             delta: RepoDelta(added: window.reduce(0) { $0 + $1.added },
                                              removed: window.reduce(0) { $0 + $1.removed },
                                              filesChanged: 12 + index * 9))
        }
    }

    /// The project-level history is the per-day sum of the repos' histories.
    static func codeStatsHistory(now: Date) -> [CodeStatsPoint] {
        let repos = repoStats(now: now)
        let total = codeStats(now: now)
        guard let days = repos.first?.history.count else { return [] }
        return (0..<days).map { i in
            let points = repos.map { $0.history[i] }
            let lines = points.reduce(0) { $0 + $1.netLines }
            return CodeStatsPoint(date: points[0].date, totalLines: lines,
                                  code: Int(Double(lines) * Double(total.code) / Double(total.totalLines)),
                                  comment: Int(Double(lines) * Double(total.comment) / Double(total.totalLines)),
                                  blank: Int(Double(lines) * Double(total.blank) / Double(total.totalLines)),
                                  totalFiles: total.totalFiles - (days - 1 - i),
                                  dayAdded: points.reduce(0) { $0 + $1.dayAdded },
                                  dayRemoved: points.reduce(0) { $0 + $1.dayRemoved },
                                  codeAdded: points.reduce(0) { $0 + $1.codeAdded },
                                  codeRemoved: points.reduce(0) { $0 + $1.codeRemoved },
                                  dataAdded: points.reduce(0) { $0 + $1.dataAdded },
                                  dataRemoved: points.reduce(0) { $0 + $1.dataRemoved })
        }
    }
}
