import SwiftUI
import GroveCore

/// Project scope (route .project(id)): back chevron + project name + search
/// (⌘F) + refresh (⌘R) + gear (-> per-project settings) in the header, the
/// capsule tab strip (Workspaces | Graph | Claude — Accounts is its own route),
/// and the selected tab's screen at full width.
struct ProjectScreen: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            BackButton { state.goBack() }
            Text(state.selectedProject?.name ?? "Project")
                .font(.headline)
                .lineLimit(1)
            searchField
            Spacer()
            AggregateChip(window: "5h",
                          aggregate: state.aggregateRemaining(window: .fiveHour, now: Date()))
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
            .help("Rescan this project (⌘R)")
            Button {
                if let id = state.selectedProjectID {
                    state.open(.projectSettings(id))
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Project settings")
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
        .modifier(SearchFieldChrome())
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f")
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    // Pure-SwiftUI tab strip (Workspaces | Graph | Claude). NOT
    // Picker(.segmented): that control is AppKit-backed and ImageRenderer draws
    // it as an error placeholder offscreen. The selected pill is REAL Liquid
    // Glass live (translucent fill in snapshots); siblings share one
    // GlassEffectContainer so the glass renders as a group when the selection
    // moves.
    private var tabStrip: some View {
        GlassEffectContainer {
            HStack(spacing: 4) {
                ForEach(MainTab.allCases, id: \.rawValue) { tab in
                    Button {
                        state.selectedTab = tab
                    } label: {
                        Text(tab.label)
                            .font(.callout.weight(state.selectedTab == tab ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .selectionCapsule(isOn: state.selectedTab == tab)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var content: some View {
        switch state.selectedTab {
        case .workspaces: WorkspacesScreen(state: state)
        case .graph: GraphScreen(state: state)
        case .stats: CodeStatsScreen(state: state)
        case .sessions: SessionsScreen(state: state)
        }
    }
}
