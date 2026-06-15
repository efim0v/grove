import SwiftUI
import GroveCore

/// Project scope (route .project(id)): a THREE-ROW header — row 1 is JUST the
/// back chevron (Esc) + project name and the per-project settings gear; row 2 is
/// the capsule tab strip (Workspaces | Graph | Stats | Claude) with the 5h
/// aggregate chip and the ⌘R rescan button trailing; row 3 is a COLLAPSIBLE
/// search (⌘F) that shows as a bare magnifier when the query is empty and the
/// field isn't focused, and expands into the full field on click/typing — then
/// the selected tab's screen at full width.
struct ProjectScreen: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @FocusState private var searchFocused: Bool
    /// Live-only expansion latch for the collapsible search row: set on ⌘F /
    /// magnifier-tap / typing so the field stays open while focused, cleared on
    /// blur-with-empty-query. Never consulted in snapshots (focus is live-only).
    @State private var searchExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            // macOS-26 grouped blocks: no flat hairline under the 3-row header —
            // the header padding + the content's own cards supply the separation.
            // Fill DOWN to the shared footer (pinned by RootView below this
            // screen) so the active tab's scroll area reaches just above it —
            // no bare-glass gap, matching the project LIST.
            content
                .frame(maxHeight: .infinity)
                // Hide-on-scroll: each tab's live ScrollView calls this when it
                // moves, re-collapsing the floating search to the magnifier. ⌘F /
                // tap still re-expand it (searchRow). Live-only — snapshots never
                // scroll, so the closure is never fired offscreen.
                .environment(\.collapseSearchOnScroll, collapseSearchOnScroll)
        }
    }

    /// Re-collapse the floating search row when the list is scrolled. Only acts
    /// when the row is actually expanded with an empty query — a scroll mustn't
    /// wipe a search the user has typed (the filtered list IS the result they're
    /// scrolling). Clearing the focus lets the existing blur watcher animate the
    /// row shut; the empty-query guard also covers the keyboard-focused case.
    private func collapseSearchOnScroll() {
        guard searchExpanded, state.searchQuery.isEmpty else { return }
        searchFocused = false
        withAnimation(.easeInOut(duration: 0.18)) { searchExpanded = false }
    }

    // MARK: - Header (3 rows)

    private var header: some View {
        VStack(spacing: 6) {
            row1
            row2
            searchRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Row 1: JUST the back affordance + project name (left) and the project
    /// settings gear (right) — every other action lives in row 2 or per-tab.
    private var row1: some View {
        HStack(spacing: 10) {
            BackButton { state.goBack() }
            Text(state.selectedProject?.name ?? "Project")
                .font(.headline)
                .lineLimit(1)
            Spacer()
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
    }

    /// Row 2: the tab strip on its own row (fits when the panel is narrow), with
    /// the 5h aggregate chip — a project-scope status badge — and the ⌘R rescan
    /// button trailing (a project-scope action, kept out of row 1 per spec).
    private var row2: some View {
        HStack(spacing: 10) {
            tabStrip
            Spacer()
            AggregateChip(window: "5h",
                          aggregate: state.aggregateRemaining(window: .fiveHour, now: Date()))
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
        }
    }

    // MARK: - Collapsible search (row 3)

    /// Collapsed = bare magnifier (query empty AND not focused/expanded). In
    /// snapshots focus is live-only, so the collapse decision rests solely on the
    /// query being empty — the fixture (empty query) renders the magnifier, while
    /// the search-test states (non-empty query) render the expanded static field.
    private var searchCollapsed: Bool {
        if isSnapshotRender { return state.searchQuery.isEmpty }
        return state.searchQuery.isEmpty && !searchFocused && !searchExpanded
    }

    /// Row 3: collapsible search. ⌘F and the magnifier both expand + focus; the
    /// hidden ⌘F button lives here so the shortcut works in BOTH states.
    private var searchRow: some View {
        HStack(spacing: 0) {
            if searchCollapsed {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { searchExpanded = true }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Search (⌘F)")
                Spacer(minLength: 0)
            } else {
                searchField
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            Button("") {
                withAnimation(.easeInOut(duration: 0.18)) { searchExpanded = true }
            }
            .keyboardShortcut("f")
            .opacity(0)
            .accessibilityHidden(true)
        )
        // Drive focus AFTER the expand commits: flipping `searchExpanded` is what
        // mounts the TextField (it lives only in the expanded branch), so a
        // synchronous `searchFocused = true` in the magnifier/⌘F closures would
        // target a not-yet-mounted field and be dropped — leaving the row stuck
        // open-but-empty (blur never fires to re-collapse). onChange runs after the
        // body re-evaluates, so the field exists and the cursor reliably lands.
        .onChange(of: searchExpanded) { _, expanded in
            if expanded { searchFocused = true }
        }
        // Re-collapse when the field loses focus with nothing typed.
        .onChange(of: searchFocused) { _, focused in
            if !focused && state.searchQuery.isEmpty {
                withAnimation(.easeInOut(duration: 0.18)) { searchExpanded = false }
            }
        }
    }

    /// Filters workspaces/branches (spec §6). The TextField is swapped for a
    /// static lookalike in snapshots (NSTextField renders as an error
    /// placeholder offscreen). Fills the row width (the collapsed state owns the
    /// bare magnifier); ⌘F is wired by `searchRow`, not here.
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
        .frame(maxWidth: .infinity)
        .modifier(SearchFieldChrome())
    }

    // Pure-SwiftUI tab strip (Workspaces | Graph | Claude). NOT
    // Picker(.segmented): that control is AppKit-backed and ImageRenderer draws
    // it as an error placeholder offscreen. The selected pill is a translucent
    // capsule (selectionCapsule); the SwiftUI GlassEffectContainer is gone — it
    // crashes nested inside the AppKit NSGlassEffectView window substrate.
    private var tabStrip: some View {
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
