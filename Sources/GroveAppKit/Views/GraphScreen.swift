import SwiftUI
import AppKit
import GroveCore

/// Commit graph tab (spec §6.2): repo selector, Canvas lane graph over the
/// last 300 commits of `git log --all` with lazy "Load more" paging, message/
/// author/relative-age columns, and ref chips (HEAD / local / origin/ remote /
/// tag) with a branch context menu: create workspace from branch, open Claude
/// in the branch's worktree (when checked out), copy name.
struct GraphScreen: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    /// Geometry shared with GraphLanesCanvas: dot x = laneOrigin + lane*laneSpacing.
    static let rowHeight: CGFloat = 24
    static let laneOrigin: CGFloat = 16
    static let laneSpacing: CGFloat = 14
    /// Fixed 8-color palette; lane color = palette[lane % 8].
    static let lanePalette: [Color] = [.cyan, .green, .orange, .purple,
                                       .pink, .yellow, .red, .blue]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            repoStrip
            Divider()
            if state.graphNodes.isEmpty {
                emptyState
            } else {
                graphBody
            }
        }
        .task(id: state.selectedProjectID) {
            // Live default selection only; the snapshot fixture pre-loads nodes.
            guard !isSnapshotRender, state.graphRepoPath == nil,
                  let repo = state.selectedSnapshot?.repos.first else { return }
            await state.loadGraph(repoPath: repo.path)
        }
    }

    // MARK: - Repo selector (pure SwiftUI capsules — snapshot-safe; NOT an
    // AppKit-backed Picker, which renders as an error placeholder offscreen)

    private var repoStrip: some View {
        HStack(spacing: 6) {
            Text("Repo")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(state.selectedSnapshot?.repos ?? [], id: \.path) { repo in
                let isSelected = repo.path == state.graphRepoPath
                Button {
                    Task { await state.loadGraph(repoPath: repo.path) }
                } label: {
                    Text(repo.dirName)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(isSelected ? AnyShapeStyle(.white.opacity(0.18))
                                               : AnyShapeStyle(.white.opacity(0.04)),
                                    in: .capsule)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("\(state.graphNodes.count) commits")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Graph body (plain VStack in snapshots: ScrollView content is
    // not rendered offscreen)

    @ViewBuilder private var graphBody: some View {
        let rows = graphRows
        if isSnapshotRender {
            VStack(alignment: .leading, spacing: 0) {
                rows
                Spacer(minLength: 0)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    rows
                }
                .padding(.bottom, 8)
            }
        }
    }

    private var graphRows: some View {
        let nodes = state.graphNodes
        let now = Date()
        let maxLane = nodes.map(\.lane).max() ?? 0
        let graphWidth = Self.laneOrigin + CGFloat(maxLane) * Self.laneSpacing + 16
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(nodes, id: \.hash) { node in
                commitRow(node, now: now)
                    .frame(height: Self.rowHeight)
                    .padding(.leading, graphWidth)
            }
            if state.graphCanLoadMore {
                Button("Load more") {
                    Task { await state.loadMoreGraph() }
                }
                .controlSize(.small)
                .padding(.leading, graphWidth)
                .padding(.vertical, 6)
            }
        }
        .background(alignment: .topLeading) {
            GraphLanesCanvas(nodes: nodes)
                .frame(width: graphWidth, height: CGFloat(nodes.count) * Self.rowHeight)
        }
        .padding(.top, 4)
    }

    private func commitRow(_ node: CommitNode, now: Date) -> some View {
        HStack(spacing: 6) {
            ForEach(refChips(node.refs)) { chip in
                refChipView(chip)
            }
            Text(node.subject)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(node.author)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(relativeAge(node.date, now: now))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.trailing, 12)
    }

    // MARK: - Ref chips

    private func chipColor(_ kind: RefKind) -> Color {
        switch kind {
        case .head: return .green
        case .local: return .cyan
        case .remote: return .purple
        case .tag: return .orange
        }
    }

    private func refChipView(_ chip: RefChip) -> some View {
        HStack(spacing: 3) {
            switch chip.kind {
            case .head: Image(systemName: "arrowtriangle.right.fill").font(.system(size: 7))
            case .remote: Image(systemName: "cloud.fill").font(.system(size: 7))
            case .tag: Image(systemName: "tag.fill").font(.system(size: 7))
            case .local: EmptyView()
            }
            Text(chip.name)
                .font(.caption2.weight(chip.kind == .head ? .bold : .medium))
        }
        .foregroundStyle(chipColor(chip.kind))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(chipColor(chip.kind).opacity(0.18), in: Capsule())
        .overlay(Capsule().strokeBorder(chipColor(chip.kind).opacity(0.5)))
        .contextMenu { chipMenu(chip) }
        .help(chip.rawRef)
    }

    /// Spec §6.2 branch-chip actions. Tags only get Copy.
    @ViewBuilder private func chipMenu(_ chip: RefChip) -> some View {
        if let branch = chip.branch {
            Button("Create workspace from this branch…") {
                // Creation is a full-screen panel state, never an overlay.
                guard let id = state.selectedProjectID else { return }
                state.createPrefill = CreatePrefill(name: sanitizedWorkspaceName(fromBranch: branch),
                                                    branch: branch, forkFrom: nil, base: branch)
                state.open(.createWorkspace(id))
            }
            if let snapshot = state.selectedSnapshot,
               let location = worktreeLocation(forBranch: branch, in: snapshot) {
                Button("Open Claude in \(location.title)") {
                    let account = state.config.accounts.first
                        ?? AccountConfig(name: "default", configDir: "~/.claude")
                    Task {
                        await state.launchClaude(cwd: location.cwd, title: location.title,
                                                 account: account, resume: nil)
                    }
                }
            } else {
                Button("Open Claude in worktree of this branch") {}
                    .disabled(true)
                    .help("Branch is not checked out in any scanned worktree")
            }
        }
        Button("Copy name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(chip.branch ?? chip.name, forType: .string)
        }
    }

    // MARK: - Empty state (spec §7)

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(state.selectedSnapshot == nil
                 ? "No scan data yet — refresh first (⌘R)."
                 : "Pick a repo to load its commit graph.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// All lanes/dots/links for the loaded page, drawn in one Canvas behind the
/// text rows. Row i center sits at y = i*rowHeight + rowHeight/2; lane L dot
/// at x = laneOrigin + L*laneSpacing. Parent links: straight vertical segment
/// on the same lane, a cubic S-curve across lanes, and a short fading stub
/// when the parent is beyond the loaded page.
struct GraphLanesCanvas: View {
    let nodes: [CommitNode]

    var body: some View {
        Canvas { context, _ in
            // First row wins on duplicate hashes (defense in depth — AppState
            // dedups pages, but a trap inside Canvas would crash the whole
            // menu-bar app; same pattern as TreeModel's session map).
            let rowOf = Dictionary(nodes.enumerated().map { ($0.element.hash, $0.offset) },
                                   uniquingKeysWith: { first, _ in first })
            func center(lane: Int, row: Int) -> CGPoint {
                CGPoint(x: GraphScreen.laneOrigin + CGFloat(lane) * GraphScreen.laneSpacing,
                        y: CGFloat(row) * GraphScreen.rowHeight + GraphScreen.rowHeight / 2)
            }
            func color(_ lane: Int) -> Color {
                GraphScreen.lanePalette[lane % GraphScreen.lanePalette.count]
            }

            // Links under the dots.
            for (row, node) in nodes.enumerated() {
                let from = center(lane: node.lane, row: row)
                for parentHash in node.parents {
                    guard let parentRow = rowOf[parentHash] else {
                        var stub = Path()
                        stub.move(to: from)
                        stub.addLine(to: CGPoint(x: from.x, y: from.y + GraphScreen.rowHeight / 2))
                        context.stroke(stub, with: .color(color(node.lane).opacity(0.35)),
                                       lineWidth: 1.5)
                        continue
                    }
                    let parent = nodes[parentRow]
                    let to = center(lane: parent.lane, row: parentRow)
                    var path = Path()
                    path.move(to: from)
                    if parent.lane == node.lane {
                        path.addLine(to: to)
                    } else {
                        let midY = (from.y + to.y) / 2
                        path.addCurve(to: to,
                                      control1: CGPoint(x: from.x, y: midY),
                                      control2: CGPoint(x: to.x, y: midY))
                    }
                    // The branch-side (higher) lane owns the link color, so a
                    // feature lane keeps its color through fork and merge.
                    let owner = max(node.lane, parent.lane)
                    context.stroke(path, with: .color(color(owner).opacity(0.8)), lineWidth: 1.5)
                }
            }

            // Dots on top.
            for (row, node) in nodes.enumerated() {
                let p = center(lane: node.lane, row: row)
                let dot = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: dot), with: .color(color(node.lane)))
            }
        }
        .allowsHitTesting(false)
    }
}
