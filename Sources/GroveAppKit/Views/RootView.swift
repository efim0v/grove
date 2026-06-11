import SwiftUI
import GroveCore

/// Panel root (spec §6): header with search (⌘F), pure-SwiftUI tab strip,
/// refresh (⌘R) and settings; error banner with a "Launch cmux" affordance
/// for cmux failures (spec §7); project sidebar; per-tab screens; footer with
/// version + Quit. A 15-second refresh loop runs while the panel content is
/// visible (.task is cancelled when the MenuBarExtra window closes).
public struct RootView: View {
    @ObservedObject private var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @FocusState private var searchFocused: Bool
    @State private var showSettings = false

    public init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            errorBanner
            HStack(spacing: 0) {
                sidebar
                Divider()
                content
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 520)
        .background(.black.opacity(0.35))
        .sheet(isPresented: $showSettings) {
            SettingsSheet(state: state)
        }
        .task {
            // Refresh now, then every 15 s while the panel stays open. The
            // task is cancelled on disappear (panel closed), pausing the loop.
            guard !isSnapshotRender else { return }
            await state.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                await state.refresh()
            }
        }
    }

    // MARK: - Header: brand, search (⌘F), tab strip, refresh, settings

    private var header: some View {
        HStack(spacing: 10) {
            Label("Grove", systemImage: "tree")
                .font(.headline)
            searchField
            Spacer()
            tabStrip
            Button {
                Task { await state.refresh() }
            } label: {
                if state.isScanning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r")
            .help("Rescan the selected project (⌘R)")
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Filters workspaces/branches (spec §6). The TextField is swapped for a
    /// static lookalike in snapshots (NSTextField renders as an error
    /// placeholder offscreen); the hidden button is the ⌘F focus target.
    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isSnapshotRender {
                Text(state.searchQuery.isEmpty ? "Search" : state.searchQuery)
                    .font(.callout)
                    .foregroundStyle(state.searchQuery.isEmpty ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Search", text: $state.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: 170)
        .background(.white.opacity(0.07), in: Capsule())
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f")
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    // Pure-SwiftUI tab strip. NOT Picker(.segmented): that control is
    // AppKit-backed and ImageRenderer draws it as an error placeholder offscreen.
    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(MainTab.allCases, id: \.rawValue) { tab in
                Button {
                    state.selectedTab = tab
                } label: {
                    Text(tab.rawValue.capitalized)
                        .font(.callout.weight(state.selectedTab == tab ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(state.selectedTab == tab ? AnyShapeStyle(.white.opacity(0.18))
                                                             : AnyShapeStyle(.clear),
                                    in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Error banner (spec §7): dismissable; cmux failures get a
    // "Launch cmux" degraded-mode affordance.

    @ViewBuilder private var errorBanner: some View {
        if let error = state.actionError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .lineLimit(2)
                    .help(error)
                Spacer()
                if error.localizedCaseInsensitiveContains("cmux") {
                    Button("Launch cmux") {
                        Task { await state.launchCmuxApp() }
                    }
                    .controlSize(.small)
                }
                Button {
                    state.actionError = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.15))
            Divider()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PROJECTS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            if state.config.projects.isEmpty {
                Text("No projects yet — add one in Settings (⚙)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.config.projects) { project in
                HStack(spacing: 6) {
                    Circle()
                        .fill(project.id == state.selectedProjectID ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(project.name)
                        .font(.callout)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture { state.selectedProjectID = project.id }
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 160, alignment: .leading)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var content: some View {
        switch state.selectedTab {
        case .workspaces: WorkspacesScreen(state: state)
        case .graph: GraphScreen(state: state)
        case .accounts: AccountsScreen(state: state)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("Grove \(GroveVersion.current)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let issue = state.configIssue {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer()
            Button("Quit Grove") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
