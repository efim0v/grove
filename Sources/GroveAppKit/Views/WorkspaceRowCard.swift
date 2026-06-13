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
            usageCaption
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

    // MARK: - Usage caption (aggregate tokens + cost + active-account chips)

    /// Per-row caption summarizing this workspace's aggregate transcript usage
    /// across accounts (Task 11). Pure SwiftUI text/chips — snapshot-safe with no
    /// gating. Omitted entirely when there's no usage yet (empty `usageByAccount`
    /// pre-refresh / snapshot without fixture data => zero tokens => render
    /// nothing, so existing PNGs don't regress).
    @ViewBuilder
    private var usageCaption: some View {
        let usage = workspaceUsage(workspace: workspace,
                                   analyticsByAccount: state.usageByAccount)
        if usage.inputTokens + usage.outputTokens > 0 {
            HStack(spacing: 8) {
                Label("\(compactTokens(usage.inputTokens + usage.outputTokens)) tok",
                      systemImage: "number")
                    .foregroundStyle(.secondary)
                Text(formatUSD(usage.cost))
                    .foregroundStyle(.secondary)
                ForEach(usage.activeAccounts, id: \.self) { account in
                    Text(account)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.white.opacity(0.06), in: Capsule())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .labelStyle(.titleAndIcon)
        }
    }

    private func compactTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fk", Double(tokens) / 1_000) }
        return String(tokens)
    }

    private func formatUSD(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
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
                // Repeated mid-row elements: a ConcentricRectangle resolves its
                // corners against the GlassCard container, so a chip adjacent to
                // a card corner inherits the card radius while an inner/mid-row
                // chip collapses to the floor — sibling chips render with
                // different corners (visual bug). A FIXED continuous radius keeps
                // every chip identical. The chip is inset from the card edge by
                // the card's 10pt content padding, so its concentric radius is
                // nested(parent: .card, inset: 10).
                .background(.white.opacity(0.06), in: RoundedRectangle(
                    cornerRadius: DesignRadius.nested(parent: DesignRadius.card, inset: 10),
                    style: .continuous))
                .help(repoState.entry.path)
            }
        }
    }

    // MARK: - Sessions — a distinct, detailed sub-table (its OWN entity, set apart
    // from the repos): status, title, account · model · tokens · cost, age, Go/Resume.

    private var sessionRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.caption2)
                Text("Sessions").font(.caption.weight(.semibold))
                Text("\(workspace.sessions.count)").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
            ForEach(Array(workspace.sessions.enumerated()), id: \.element.id) { index, session in
                if index > 0 { Divider().opacity(0.3) }
                sessionDetailRow(session)
            }
        }
        .padding(8)
        .background(sessionTableBackground)
    }

    @ViewBuilder private var sessionTableBackground: some View {
        let shape = RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous)
        if isSnapshotRender {
            shape.fill(.white.opacity(0.05)).overlay(shape.strokeBorder(.white.opacity(0.12)))
        } else {
            shape.fill(.black.opacity(0.22)).overlay(shape.strokeBorder(.white.opacity(0.08)))
        }
    }

    private func sessionDetailRow(_ session: ClaudeSession) -> some View {
        let usage = state.usageByAccount[session.accountName]?.sessions[session.id]
        let model = usage?.modelBreakdown.max { $0.value < $1.value }?.key
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(activityColor(for: session)).frame(width: 7, height: 7)
                Text(statusWord(for: session))
                    .foregroundStyle(activityColor(for: session))
                    .frame(width: 52, alignment: .leading)
                Text(displayTitle(session)).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 8)
                Text(relativeAge(session.lastActivity, now: now)).foregroundStyle(.tertiary)
                if isSnapshotRender {
                    Text(liveProcess(for: session) == nil ? "Resume" : "Go")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Button(liveProcess(for: session) == nil ? "Resume" : "Go") { open(session) }
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
            HStack(spacing: 8) {
                Text(session.accountName).foregroundStyle(.tertiary)
                if let usage {
                    Text("\(compactTokens(usage.inputTokens + usage.outputTokens)) tok")
                    Text(formatUSD(usage.cost))
                }
                if let model { Text(model).monospaced() }
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 13)
        }
        .padding(.vertical, 4)
    }

    /// running (busy/idle live) / waiting / closed (no live process).
    private func statusWord(for session: ClaudeSession) -> String {
        guard let live = liveProcess(for: session) else { return "closed" }
        return live.status == "waiting" ? "waiting" : "running"
    }

    /// Sessions whose first message is the cmux/local-command caveat get a junk
    /// title — fall back to a short id so the table stays readable.
    private func displayTitle(_ session: ClaudeSession) -> String {
        guard let title = session.title, !title.isEmpty,
              !title.hasPrefix("<"), !title.hasPrefix("Caveat:")
        else { return "session \(session.id.prefix(6))" }
        return title
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

    private var cmuxButton: some View {
        CmuxButton(state: state, matches: workspace.cmuxWorkspaces,
                   newWorkspaceCwd: workspace.umbrellaPath,
                   newWorkspaceTitle: workspace.name)
    }
}

/// The cmux action for one worktree context (workspace action bar / loose
/// row). Matches come from current_directory equality — but a cmux
/// workspace's current_directory is the cwd of its FOCUSED PANE, i.e.
/// transient: any long-lived workspace merely cd'd into the worktree gets
/// matched (v1.2.1 fix 2, diagnosed live). So with matches the button is a
/// Menu — "Go to <title>" per match PLUS "New cmux workspace here" as the
/// escape hatch — whose primaryAction (plain click) jumps to the first match,
/// preserving the old single-click behavior. With no match it stays the plain
/// "cmux" -> new shell workspace button (spec §6.1: never a dead control).
struct CmuxButton: View {
    @ObservedObject var state: AppState
    let matches: [CmuxWorkspace]
    let newWorkspaceCwd: String
    let newWorkspaceTitle: String
    /// Menu renders as a yellow placeholder under ImageRenderer — snapshot
    /// mode swaps in a plain-Button lookalike with the primary action, so the
    /// PNGs keep showing the same "cmux" label.
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        if matches.isEmpty {
            Button("cmux") { openShell() }
                .help("Open a new cmux shell workspace here")
        } else if isSnapshotRender {
            Button("cmux") { goToFirst() }
        } else {
            Menu("cmux") {
                ForEach(matches, id: \.id) { match in
                    Button("Go to “\(match.title.isEmpty ? match.id : match.title)”") {
                        Task { await state.goToCmux(match) }
                    }
                }
                Divider()
                Button("New cmux workspace here") { openShell() }
            } primaryAction: {
                goToFirst()
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Click: go to the matched cmux workspace; menu: all matches or a new one")
        }
    }

    private func goToFirst() {
        guard let first = matches.first else { return }
        Task { await state.goToCmux(first) }
    }

    private func openShell() {
        Task { await state.openCmuxShell(cwd: newWorkspaceCwd, title: newWorkspaceTitle) }
    }
}
