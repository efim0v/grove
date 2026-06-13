import SwiftUI
import AppKit
import GroveCore

/// The root scope (route .projects): a two-tab shell (item 4) — Projects (the
/// primary view: project list with quick session access) and Charts (the usage
/// dashboard). The tab selection lives in AppState so it survives the panel
/// closing/reopening. Header + footer are shared across both tabs.
struct RootShell: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
    }

    // MARK: - Header: brand + tab strip + add (Projects only)

    private var header: some View {
        HStack(spacing: 10) {
            Label("Grove", systemImage: "tree")
                .font(.headline)
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 8)
            tabStrip
            Spacer(minLength: 8)
            Button { addProjectViaPanel() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .help("Add a project directory")
                .opacity(state.rootTab == .projects ? 1 : 0)
                .disabled(state.rootTab != .projects)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Capsule segmented strip (Liquid Glass live; snapshot-safe fill offscreen),
    /// matching the project-scope tab strip the app already uses.
    private var tabStrip: some View {
        GlassEffectContainer {
            HStack(spacing: 4) {
                ForEach(RootTab.allCases, id: \.rawValue) { tab in
                    Button {
                        state.rootTab = tab
                    } label: {
                        Label(tab.label, systemImage: tab.systemImage)
                            .font(.callout.weight(state.rootTab == tab ? .semibold : .regular))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .selectionCapsule(isOn: state.rootTab == tab)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Tab content

    @ViewBuilder private var content: some View {
        switch state.rootTab {
        case .projects: ProjectsTab(state: state)
        case .charts: DashboardScreen(state: state)
        }
    }

    // MARK: - Footer: Accounts, settings, refresh, version, Quit

    private var footer: some View {
        HStack(spacing: 10) {
            Button { state.open(.accounts) } label: {
                Label("Accounts", systemImage: "person.2").font(.callout)
            }
            .buttonStyle(.plain)
            .help("Claude accounts")
            Button { state.open(.globalSettings) } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            Button {
                Task { await state.refresh() }
            } label: {
                if state.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r")
            .help("Refresh (⌘R)")
            if let issue = state.configIssue {
                Text(issue).font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            Text("Grove \(GroveVersion.current)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// NSOpenPanel is LIVE-only (it sits behind a button action, so snapshot
    /// rendering never reaches it).
    private func addProjectViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        if panel.runModal() == .OK, let url = panel.url {
            state.addProject(at: url.path)
        }
    }
}
