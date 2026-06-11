import SwiftUI
import GroveCore

/// One workspace node (spec §6.1): collapsed header with name + badge strip,
/// expandable body with per-repo chips, session rows and the Claude/cmux
/// action bar. All actions go through AppState (errors land in actionError).
struct WorkspaceRowCard: View {
    @ObservedObject var state: AppState
    let workspace: FeatureWorkspace
    let badges: WorkspaceBadges
    let isExpanded: Bool
    let now: Date
    let onToggle: () -> Void
    /// Opens the create screen prefilled with forkFrom = this workspace
    /// ("+ child workspace", spec §6.1 node context).
    var onCreateChild: (() -> Void)? = nil
    /// ImageRenderer landmine (verified in this task's PNGs): SwiftUI `Menu`
    /// and `.buttonStyle(.link)` render as yellow/crossed placeholders
    /// offscreen — snapshot mode swaps in static lookalikes.
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded {
                Divider()
                repoChips
                if !workspace.sessions.isEmpty {
                    sessionRows
                }
                actionBar
            }
        }
        .padding(10)
        .glassCard()
        .contextMenu {
            if let onCreateChild {
                Button("New child workspace…") { onCreateChild() }
            }
        }
    }

    // MARK: - Header + badges

    private var header: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Circle()
                    .fill(ageColor)
                    .frame(width: 8, height: 8)
                Text(workspace.name)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 12)
                badgeStrip
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var ageColor: Color {
        switch badges.ageBucket {
        case .fresh: return .green
        case .aging: return .orange
        case .stale: return .red
        case .unknown: return .gray
        }
    }

    /// Traffic-light age, dirty total, busy/waiting/resumable counts.
    private var badgeStrip: some View {
        HStack(spacing: 10) {
            if let days = badges.ageDays {
                Label("\(days)d", systemImage: "clock")
                    .foregroundStyle(ageColor)
            }
            if badges.dirtyTotal > 0 {
                Label("\(badges.dirtyTotal)", systemImage: "pencil")
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
            }
            if badges.busyCount > 0 {
                Label("\(badges.busyCount)", systemImage: "circle.fill")
                    .foregroundStyle(.green)
            }
            if badges.waitingCount > 0 {
                Label("\(badges.waitingCount)", systemImage: "circle.fill")
                    .foregroundStyle(.yellow)
            }
            if badges.resumableCount > 0 {
                Label("\(badges.resumableCount)", systemImage: "circle.dotted")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }

    // MARK: - Repo chips (branch, start point, +ahead/−behind, dirty; path as tooltip)

    private var repoChips: some View {
        HStack(spacing: 6) {
            ForEach(workspace.repos, id: \.repo.path) { repoState in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "shippingbox")
                        Text(repoState.repo.dirName).fontWeight(.medium)
                    }
                    HStack(spacing: 6) {
                        Text(repoState.entry.branch ?? "detached")
                        if let meta = repoState.meta {
                            Text("from \(meta.baseBranch)")
                                .foregroundStyle(.tertiary)
                            Text("+\(meta.ahead)").foregroundStyle(.green)
                            Text("−\(meta.behind)").foregroundStyle(.red)
                            Text(meta.dirtyCount > 0 ? "✎\(meta.dirtyCount)" : "✓")
                                .foregroundStyle(meta.dirtyCount > 0 ? .orange : .secondary)
                        }
                        if let error = repoState.scanError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .help(error)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                // Concentric with the card's DesignRadius.card container shape
                // (GlassCard declares it); the minimum keeps mid-card chips —
                // too far from any card corner to resolve — at the concentric
                // radius for the card's 10pt content padding.
                .background(.white.opacity(0.06), in: ConcentricRectangle(corners: .concentric(
                    minimum: .fixed(DesignRadius.nested(parent: DesignRadius.card, inset: 10)))))
                .help(repoState.entry.path)
            }
        }
    }

    // MARK: - Session rows (activity dot, title, account, relative age, open)

    private var sessionRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(workspace.sessions, id: \.id) { session in
                HStack(spacing: 6) {
                    Circle()
                        .fill(activityColor(for: session))
                        .frame(width: 6, height: 6)
                    Text(session.title ?? "(untitled session)")
                        .lineLimit(1)
                    Text(session.accountName)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    Text(relativeAge(session.lastActivity, now: now))
                        .foregroundStyle(.secondary)
                    if isSnapshotRender {
                        // .buttonStyle(.link) draws a yellow placeholder
                        // offscreen — static link-colored lookalike instead.
                        Text(liveProcess(for: session) == nil ? "Resume" : "Go")
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Button(liveProcess(for: session) == nil ? "Resume" : "Go") {
                            open(session)
                        }
                        .buttonStyle(.link)
                    }
                }
                .font(.caption)
            }
        }
    }

    private func liveProcess(for session: ClaudeSession) -> LiveProcess? {
        workspace.liveProcesses.first { $0.sessionId == session.id }
    }

    /// busy -> green, waiting -> yellow, other live -> cyan, no process -> gray.
    private func activityColor(for session: ClaudeSession) -> Color {
        guard let live = liveProcess(for: session) else { return .gray }
        switch live.status {
        case "busy": return .green
        case "waiting": return .yellow
        default: return .cyan
        }
    }

    private func open(_ session: ClaudeSession) {
        let account = state.config.accounts.first { $0.name == session.accountName }
            ?? state.config.accounts.first
            ?? AccountConfig(name: "default", configDir: "~/.claude")
        Task {
            await state.goToSession(session, fallbackCwd: workspace.umbrellaPath,
                                    fallbackTitle: workspace.name, account: account)
        }
    }

    // MARK: - Action bar: New Claude (account menu), Resume, go-to-cmux

    private var actionBar: some View {
        HStack(spacing: 8) {
            if isSnapshotRender {
                // Menu draws a yellow placeholder offscreen — a plain Button
                // (which renders fine) stands in with the primary action.
                Button("New Claude") {
                    if let account = state.defaultLaunchAccount { launch(account: account) }
                }
            } else {
                Menu("New Claude") {
                    ForEach(state.config.accounts, id: \.name) { account in
                        Button(account.name) { launch(account: account) }
                    }
                } primaryAction: {
                    // Single click launches on the project's default account
                    // (falling back to the first one), spec §6.1.
                    if let account = state.defaultLaunchAccount { launch(account: account) }
                }
                .menuStyle(.button)
                .fixedSize()
            }

            Button("Resume") {
                if let session = latestResumable { open(session) }
            }
            .disabled(latestResumable == nil)

            cmuxButton
            if let onCreateChild {
                Button {
                    onCreateChild()
                } label: {
                    Label("Child", systemImage: "plus")
                }
                .help("Create a stacked child workspace forked from this one")
            }
            Spacer()
        }
        .font(.caption)
        .controlSize(.small)
    }

    /// Newest session that has no matching live process (sessions arrive
    /// sorted newest-first from WorkspaceService).
    private var latestResumable: ClaudeSession? {
        workspace.sessions.first { liveProcess(for: $0) == nil }
    }

    private func launch(account: AccountConfig) {
        Task {
            await state.launchClaude(cwd: workspace.umbrellaPath, title: workspace.name,
                                     account: account, resume: nil)
        }
    }

    @ViewBuilder private var cmuxButton: some View {
        if workspace.cmuxWorkspaces.count > 1 {
            if isSnapshotRender {
                // Menu placeholder landmine again: Button lookalike jumping
                // to the first matching cmux workspace.
                Button("cmux") {
                    if let first = workspace.cmuxWorkspaces.first {
                        Task { await state.goToCmux(first) }
                    }
                }
            } else {
                Menu("cmux") {
                    ForEach(workspace.cmuxWorkspaces, id: \.id) { cmuxWorkspace in
                        Button(cmuxWorkspace.title.isEmpty ? cmuxWorkspace.id : cmuxWorkspace.title) {
                            Task { await state.goToCmux(cmuxWorkspace) }
                        }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
            }
        } else if let cmuxWorkspace = workspace.cmuxWorkspaces.first {
            Button("cmux") { Task { await state.goToCmux(cmuxWorkspace) } }
        } else {
            // Spec §6.1: never a dead control — create a shell-only cmux
            // workspace at the umbrella and jump to it (Steps 5a/5b).
            Button("cmux") {
                Task {
                    await state.openCmuxShell(cwd: workspace.umbrellaPath,
                                              title: workspace.name)
                }
            }
            .help("Open a new cmux shell workspace here")
        }
    }
}
