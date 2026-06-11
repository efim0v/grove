import SwiftUI
import GroveCore

/// Box-drawing-style connector lanes for one tree row, drawn with Canvas:
/// columns 0..<depth carry ancestor trunks (a vertical │ when that lineage
/// continues below this row), column `depth` draws this node's elbow
/// (├─ when more siblings follow, └─ for the last one). Rows stack with
/// spacing 0, so per-row full-height trunks join into continuous lines.
struct TreeConnector: View {
    let depth: Int
    let ancestorContinues: [Bool]
    let isLast: Bool

    static let indent: CGFloat = 20
    static let palette: [Color] = [.green, .orange, .purple, .cyan, .pink, .yellow]

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            func centerX(_ column: Int) -> CGFloat {
                CGFloat(column) * Self.indent + Self.indent / 2
            }
            func color(_ column: Int) -> GraphicsContext.Shading {
                .color(Self.palette[column % Self.palette.count].opacity(0.8))
            }

            for column in 0..<depth where column < ancestorContinues.count && ancestorContinues[column] {
                var trunk = Path()
                trunk.move(to: CGPoint(x: centerX(column), y: 0))
                trunk.addLine(to: CGPoint(x: centerX(column), y: size.height))
                context.stroke(trunk, with: color(column), lineWidth: 1.5)
            }

            var elbow = Path()
            elbow.move(to: CGPoint(x: centerX(depth), y: 0))
            elbow.addLine(to: CGPoint(x: centerX(depth), y: isLast ? midY : size.height))
            context.stroke(elbow, with: color(depth), lineWidth: 1.5)

            var arm = Path()
            arm.move(to: CGPoint(x: centerX(depth), y: midY))
            arm.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(arm, with: color(depth), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

/// Primary tab (spec §6.1): the workspace TREE grown from the base branches,
/// a flat recency-sorted alternative ("≡ список"), and the loose-worktrees
/// section grouped by leaf directory name.
struct WorkspacesScreen: View {
    @ObservedObject var state: AppState
    /// Task 15 landmine flag: ImageRenderer does not render ScrollView content
    /// offscreen, so snapshot mode swaps the container to a plain stack.
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    /// Task 18's seam for workspaces-expanded.png: workspace names in this set
    /// render expanded with zero interaction (unioned with `expanded` below).
    @Environment(\.snapshotExpandedWorkspaces) private var snapshotExpanded

    @State private var expanded: Set<String> = []
    @State private var flatList = false
    @State private var looseExpanded = true
    @State private var createPrefill: CreatePrefill?

    init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
    }

    var body: some View {
        if let snapshot = state.selectedSnapshot {
            content(snapshot: snapshot)
        } else {
            emptyState
        }
    }

    // MARK: - Content

    private func content(snapshot: ProjectSnapshot) -> some View {
        let now = Date()
        let allRows = buildWorkspaceTree(snapshot, now: now)
        let rows = filterTree(allRows, query: state.searchQuery)
        let visible = flatList ? flattenByRecency(rows) : rows
        return Group {
            if isSnapshotRender {
                // ImageRenderer does not render ScrollView content offscreen
                // (Task 15 finding): snapshot mode lays the column out
                // unscrolled so every card is visible in the PNGs.
                cardsColumn(snapshot: snapshot, visible: visible, now: now)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    cardsColumn(snapshot: snapshot, visible: visible, now: now)
                }
            }
        }
        // NOT .sheet: a real sheet is a second key window, which auto-hides
        // the MenuBarExtra(.window) panel (see PanelOverlay.swift).
        .panelOverlay(item: $createPrefill) { prefill in
            CreateWorkspaceSheet(state: state, prefill: prefill,
                                 onClose: { createPrefill = nil })
        }
    }

    /// The whole column, extracted so `content` can swap its container:
    /// ScrollView live, plain unscrolled stack in snapshot mode.
    private func cardsColumn(snapshot: ProjectSnapshot, visible: [WorkspaceTreeRow],
                             now: Date) -> some View {
        // Plain VStack, NOT LazyVStack: ImageRenderer renders lazy
        // containers blank, and workspace counts are small anyway.
        VStack(alignment: .leading, spacing: 0) {
            screenHeader(snapshot: snapshot)
            if visible.isEmpty {
                noWorkspacesHint(snapshot: snapshot)
            } else {
                if !flatList { baseHeader(snapshot: snapshot) }
                ForEach(visible) { row in
                    rowView(row, now: now)
                }
            }
            looseSection(snapshot: snapshot)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func rowView(_ row: WorkspaceTreeRow, now: Date) -> some View {
        let connectorWidth = flatList ? 0 : CGFloat(row.depth + 1) * TreeConnector.indent
        return WorkspaceRowCard(
            state: state,
            workspace: row.workspace,
            badges: row.badges,
            isExpanded: isExpanded(row.name),
            now: now,
            onToggle: { toggle(row.name) },
            onCreateChild: { createPrefill = CreatePrefill(forkFrom: row.workspace) }
        )
        .padding(.vertical, 3)
        .padding(.leading, connectorWidth)
        .background(alignment: .leading) {
            if !flatList {
                TreeConnector(depth: row.depth,
                              ancestorContinues: row.ancestorContinues,
                              isLast: row.isLast)
                    .frame(width: connectorWidth)
            }
        }
    }

    /// Interactive expansion unioned with the snapshot pre-expansion seam.
    private func isExpanded(_ name: String) -> Bool {
        expanded.contains(name) || snapshotExpanded.contains(name)
    }

    private func toggle(_ name: String) {
        if expanded.contains(name) {
            expanded.remove(name)
        } else {
            expanded.insert(name)
        }
    }

    // MARK: - Header row (project name + tree/list toggle)

    private func screenHeader(snapshot: ProjectSnapshot) -> some View {
        HStack {
            Text(snapshot.project.name)
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                createPrefill = CreatePrefill()
            } label: {
                Label("Workspace", systemImage: "plus")
            }
            .controlSize(.small)
            viewToggle
        }
        .padding(.vertical, 10)
    }

    /// Pure-SwiftUI tree/list toggle in the capsule style of RootView's tab
    /// strip (Task 15). NOT Picker(.segmented): segmented controls are
    /// AppKit-backed and ImageRenderer draws them as a yellow error
    /// placeholder offscreen.
    private var viewToggle: some View {
        HStack(spacing: 4) {
            toggleButton("point.3.connected.trianglepath.dotted", isOn: !flatList,
                         help: "Tree") { flatList = false }
            toggleButton("list.bullet", isOn: flatList,
                         help: "Flat list") { flatList = true }
        }
    }

    private func toggleButton(_ systemImage: String, isOn: Bool, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isOn ? AnyShapeStyle(.white.opacity(0.18))
                                 : AnyShapeStyle(.clear),
                            in: .capsule)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The trunk all roots hang from: "base" plus the base branches seen by the scan.
    private func baseHeader(snapshot: ProjectSnapshot) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(white: 0.6))
                .frame(width: 7, height: 7)
                .padding(.leading, 7)   // centers on TreeConnector column 0
            Text("base")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(baseSummary(snapshot: snapshot))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.bottom, 2)
    }

    private func baseSummary(snapshot: ProjectSnapshot) -> String {
        // Stacked children measure against their PARENT's feature branch, so only
        // root workspaces (parentName == nil) contribute real base branches here.
        let bases = Set(snapshot.workspaces
            .filter { $0.parentName == nil }
            .flatMap { workspace in
                workspace.repos.compactMap { $0.meta?.baseBranch }
            })
        return bases.sorted().joined(separator: " · ")
    }

    // MARK: - Loose worktrees, grouped by leaf directory name

    @ViewBuilder
    private func looseSection(snapshot: ProjectSnapshot) -> some View {
        let groups = looseGroups(snapshot: snapshot)
        if !groups.isEmpty {
            DisclosureGroup(isExpanded: $looseExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groups, id: \.leaf) { group in
                        looseGroupView(group)
                    }
                }
            } label: {
                Text("Loose worktrees (\(snapshot.loose.count))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 14)
        }
    }

    private func looseGroups(snapshot: ProjectSnapshot) -> [(leaf: String, members: [LooseWorktree])] {
        let query = state.searchQuery
        let filtered = snapshot.loose.filter { loose in
            guard !query.isEmpty else { return true }
            let leaf = (loose.entry.path as NSString).lastPathComponent
            return leaf.localizedCaseInsensitiveContains(query)
                || (loose.entry.branch?.localizedCaseInsensitiveContains(query) ?? false)
        }
        let grouped = Dictionary(grouping: filtered) { ($0.entry.path as NSString).lastPathComponent }
        return grouped.keys.sorted().map { (leaf: $0, members: grouped[$0]!) }
    }

    private func looseGroupView(_ group: (leaf: String, members: [LooseWorktree])) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(group.leaf)
                .font(.caption.weight(.semibold))
            ForEach(group.members, id: \.entry.path) { loose in
                looseRow(loose)
            }
        }
        .padding(8)
        .glassCard()
        .padding(.vertical, 2)
    }

    private func looseRow(_ loose: LooseWorktree) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(loose.repo.dirName)
                    .foregroundStyle(.secondary)
                Text(loose.entry.branch ?? "detached")
                if let meta = loose.meta {
                    Text("+\(meta.ahead)").foregroundStyle(.green)
                    Text("−\(meta.behind)").foregroundStyle(.red)
                    Text(meta.dirtyCount > 0 ? "✎\(meta.dirtyCount)" : "✓")
                        .foregroundStyle(meta.dirtyCount > 0 ? .orange : .secondary)
                }
                Spacer()
                if isSnapshotRender {
                    // ImageRenderer landmine (verified in this task's PNGs):
                    // Menu draws a yellow placeholder offscreen — a plain
                    // Button stands in with the first-account action.
                    Button("Claude") {
                        if let account = state.config.accounts.first {
                            Task {
                                await state.launchClaude(
                                    cwd: loose.entry.path,
                                    title: (loose.entry.path as NSString).lastPathComponent,
                                    account: account, resume: nil)
                            }
                        }
                    }
                } else {
                    Menu("Claude") {
                        ForEach(state.config.accounts, id: \.name) { account in
                            Button(account.name) {
                                Task {
                                    await state.launchClaude(
                                        cwd: loose.entry.path,
                                        title: (loose.entry.path as NSString).lastPathComponent,
                                        account: account, resume: nil)
                                }
                            }
                        }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                }
                if let cmuxWorkspace = loose.cmuxWorkspaces.first {
                    Button("cmux") { Task { await state.goToCmux(cmuxWorkspace) } }
                }
            }
            // Spec §2: loose rows list their sessions too, with the same
            // Resume / go-to routing as workspace cards (goToSession picks the
            // hook-mapped cmux workspace first, --resume relaunch as fallback).
            ForEach(loose.sessions, id: \.id) { session in
                looseSessionRow(session, loose: loose)
            }
        }
        .font(.caption)
        .controlSize(.small)
        .help(loose.entry.path)
    }

    private func looseSessionRow(_ session: ClaudeSession, loose: LooseWorktree) -> some View {
        let isLive = loose.liveProcesses.contains { $0.sessionId == session.id }
        return HStack(spacing: 6) {
            Circle()
                .fill(isLive ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(session.title ?? "(untitled session)")
                .lineLimit(1)
            Text(session.accountName)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Text(relativeAge(session.lastActivity, now: Date()))
                .foregroundStyle(.secondary)
            if isSnapshotRender {
                // .buttonStyle(.link) draws a yellow placeholder offscreen —
                // static link-colored lookalike instead.
                Text(isLive ? "Go" : "Resume")
                    .foregroundStyle(Color.accentColor)
            } else {
                Button(isLive ? "Go" : "Resume") {
                    let account = state.config.accounts.first { $0.name == session.accountName }
                        ?? state.config.accounts.first
                        ?? AccountConfig(name: "default", configDir: "~/.claude")
                    Task {
                        await state.goToSession(
                            session,
                            fallbackCwd: loose.entry.path,
                            fallbackTitle: (loose.entry.path as NSString).lastPathComponent,
                            account: account)
                    }
                }
                .buttonStyle(.link)
            }
        }
        .padding(.leading, 14)
    }

    // MARK: - Empty states (spec §7)

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tree")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No project selected")
                .font(.headline)
            Text("Add or select a project in the sidebar, then refresh (⌘R).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noWorkspacesHint(snapshot: ProjectSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.searchQuery.isEmpty
                 ? "No workspaces yet"
                 : "No workspaces match “\(state.searchQuery)”")
                .font(.subheadline)
            if state.searchQuery.isEmpty {
                Text(snapshot.repos.isEmpty
                     ? "No repos found (scan depth \(snapshot.project.scanDepth))."
                     : "\(snapshot.repos.count) repo(s) found — create the first workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 20)
    }
}
