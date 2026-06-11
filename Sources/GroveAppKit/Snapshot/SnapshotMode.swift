import AppKit
import SwiftUI
import GroveCore

/// Agent-verifiable UI harness: `GroveApp --snapshot <outDir>` renders the app
/// with a synthetic fixture state into PNGs and exits without ever starting
/// NSApplication. Task 15 skeleton: 1-workspace fixture, root-workspaces.png
/// only. Task 18 grows the fixture and renders all six scenes.
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
            workspacesRoot: "/Users/demo/Workspaces/acme.shop"
        )
        state.config = GroveConfig(
            version: 1,
            workspacesRootTemplate: "~/Workspaces/{project}",
            projects: [project],
            accounts: [
                AccountConfig(name: "default", configDir: "~/.claude"),
                AccountConfig(name: "work", configDir: "~/.claude-accounts/work"),
            ]
        )
        state.snapshots = [project.id: fixtureSnapshot(project: project, now: Date())]
        state.selectedProjectID = project.id
        return state
    }

    /// Ages are relative to `now` (real clock at render time) because the
    /// views compute badges against Date() — fixed dates would drift.
    static func fixtureSnapshot(project: ProjectConfig, now: Date) -> ProjectSnapshot {
        let root = "/Users/demo/Workspaces/acme.shop"
        let client = RepoInfo(path: project.path + "/acme_client", dirName: "acme_client")
        let umbrella = root + "/media-pipeline"
        let workspace = FeatureWorkspace(
            name: "media-pipeline",
            umbrellaPath: umbrella,
            repos: [
                WorkspaceRepoState(
                    repo: client,
                    entry: WorktreeEntry(path: umbrella + "/acme_client",
                                         branch: "feat/media-pipeline",
                                         head: "aaaa111", isMain: false),
                    meta: WorktreeMeta(baseBranch: "dev", forkPoint: "ffff000",
                                       forkDate: now.addingTimeInterval(-6 * 86_400),
                                       ahead: 14, behind: 2, dirtyCount: 8,
                                       lastCommitDate: now.addingTimeInterval(-3_600),
                                       lastCommitSubject: "wire upload progress events"),
                    scanError: nil),
            ],
            parentName: nil,
            sessions: [
                ClaudeSession(id: "s-mp-1", cwd: umbrella,
                              title: "Implement media pipeline",
                              lastActivity: now.addingTimeInterval(-900),
                              accountName: "default",
                              gitBranch: "feat/media-pipeline"),
            ],
            liveProcesses: [
                LiveProcess(pid: 4242, sessionId: "s-mp-1", cwd: umbrella,
                            status: "busy", accountName: "default"),
            ],
            cmuxWorkspaces: [
                CmuxWorkspace(id: "ws-101", title: "media-pipeline", currentDirectory: umbrella),
            ]
        )
        return ProjectSnapshot(project: project, repos: [client],
                               workspaces: [workspace], loose: [], errors: [])
    }

    // MARK: - Rendering

    @MainActor
    static func renderAll(into outDir: URL) throws -> Int {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let state = fixtureState()
        try writePNG(RootView(state: state),
                     to: outDir.appendingPathComponent("root-workspaces.png"))
        return 1
    }

    /// Offscreen render at 760x520 logical points, scale 2 (1520x1040 px).
    /// CAVEAT: ImageRenderer has no window/backdrop, so .glassEffect-modified
    /// views render INVISIBLE offscreen — \.isSnapshotRender makes GlassCard
    /// fall back to a plain translucent card. Snapshots verify LAYOUT and
    /// CONTENT, never glass blur. The dark gradient stands in for the missing
    /// desktop/panel material.
    @MainActor
    static func writePNG<Content: View>(_ content: Content, to url: URL) throws {
        let wrapped = ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.14),
                                    Color(red: 0.16, green: 0.13, blue: 0.20)],
                           startPoint: .top, endPoint: .bottom)
            content
        }
        .frame(width: 760, height: 520)
        .environment(\.colorScheme, .dark)
        .environment(\.isSnapshotRender, true)

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
