import SwiftUI
import GroveCore

/// Third project tab (spec §3): a table of ALL Claude sessions of the selected
/// project — live processes joined with scanned transcripts — with full
/// visibility (status, runtime, location, account) and control (Go / Resume,
/// plus cross-account "Resume as <name>"). Pure-SwiftUI rows so it renders
/// under ImageRenderer (Picker/Menu/.link controls are AppKit-backed and draw
/// as placeholders offscreen — gated on \.isSnapshotRender like the rest).
struct SessionsScreen: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
    }

    var body: some View {
        if let snapshot = state.selectedSnapshot {
            content(snapshot: snapshot)
        } else {
            emptyState(text: "Refresh (⌘R) to scan this project's Claude sessions.")
        }
    }

    // MARK: - Content

    private func content(snapshot: ProjectSnapshot) -> some View {
        let now = Date()
        let rows = filterRows(buildSessionRows(snapshot: snapshot,
                                               cmuxMap: cmuxMap()),
                              query: state.searchQuery)
        return Group {
            if rows.isEmpty {
                emptyState(text: state.searchQuery.isEmpty
                           ? "No Claude sessions in this project yet."
                           : "No sessions match “\(state.searchQuery)”.")
            } else if isSnapshotRender {
                // ImageRenderer does not render ScrollView content offscreen:
                // lay the table out unscrolled so every row shows in the PNG.
                table(rows: rows, now: now)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView { table(rows: rows, now: now) }
            }
        }
    }

    /// Hook registry in normal use; snapshot mode passes an empty map (the
    /// busy session still maps to Go via the cmux-workspace-lists-cwd path).
    private func cmuxMap() -> [String: String] {
        isSnapshotRender ? [:]
            : (state.cmuxOverride ?? CmuxService())
                .claudeSessionWorkspaceMap(hookFile: state.cmuxHookFile)
    }

    private func filterRows(_ rows: [SessionRow], query: String) -> [SessionRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { $0.title.lowercased().contains(needle) }
    }

    // MARK: - Table

    private func table(rows: [SessionRow], now: Date) -> some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                sessionRow(row, now: now)
                if index < rows.count - 1 { Divider().opacity(0.4) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Text("Status").frame(width: Self.statusWidth, alignment: .leading)
            Text("Session").frame(maxWidth: .infinity, alignment: .leading)
            Text("Location").frame(width: Self.locationWidth, alignment: .leading)
            Text("Account").frame(width: Self.accountWidth, alignment: .leading)
            Text("").frame(width: Self.actionWidth, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    static let statusWidth: CGFloat = 132
    static let locationWidth: CGFloat = 130
    static let accountWidth: CGFloat = 80
    static let actionWidth: CGFloat = 130

    private func sessionRow(_ row: SessionRow, now: Date) -> some View {
        HStack(spacing: 10) {
            statusCell(row, now: now).frame(width: Self.statusWidth, alignment: .leading)
            Text(row.title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.location)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Self.locationWidth, alignment: .leading)
            Text(row.accountName)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: Self.accountWidth, alignment: .leading)
            actionCell(row).frame(width: Self.actionWidth, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { performPrimary(row) }
        .help(row.cwd)
    }

    // MARK: - Status cell

    @ViewBuilder
    private func statusCell(_ row: SessionRow, now: Date) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor(row.liveStatus))
                .frame(width: 7, height: 7)
            if let status = row.liveStatus {
                Text(statusWord(status))
                    .foregroundStyle(.primary)
                if let startedAt = row.startedAt {
                    Text(relativeAge(startedAt, now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("resumable")
                    .foregroundStyle(.secondary)
                Text(relativeAge(row.lastActivity, now: now))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func dotColor(_ status: SessionLiveStatus?) -> Color {
        switch status {
        case .busy: return .green
        case .waiting: return .yellow
        case .idle: return Color(red: 0.4, green: 0.7, blue: 0.75)   // gray-cyan
        case nil: return .gray
        }
    }

    private func statusWord(_ status: SessionLiveStatus) -> String {
        switch status {
        case .busy: return "busy"
        case .waiting: return "waiting"
        case .idle: return "idle"
        }
    }

    // MARK: - Action cell

    @ViewBuilder
    private func actionCell(_ row: SessionRow) -> some View {
        if row.action == .go {
            // The whole row is tappable (-> performPrimary); the label is the
            // affordance text.
            actionLabel("Go")
        } else {
            // Resumable: "Resume" under the owning account (row tap), plus a
            // chevron menu offering "Resume as <name>" for every OTHER
            // configured account (cross-account resume — verdict: FEASIBLE).
            HStack(spacing: 4) {
                actionLabel("Resume")
                resumeAsMenu(row)
            }
        }
    }

    private func actionLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Color.accentColor)
    }

    /// Other-account selector. Snapshot-safe: a static chevron lookalike
    /// offscreen (Menu is AppKit-backed), a real Menu live.
    @ViewBuilder
    private func resumeAsMenu(_ row: SessionRow) -> some View {
        let others = state.config.accounts.filter { $0.name != row.accountName }
        if !others.isEmpty {
            if isSnapshotRender {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(others, id: \.name) { account in
                        Button("Resume as \(account.name)") {
                            resume(row, as: account)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 16)
            }
        }
    }

    // MARK: - Actions

    /// Row click / primary button: Go jumps to the cmux workspace the row
    /// already resolved (`cmuxWorkspaceId` — hook map OR cwd match); Resume
    /// relaunches under the session's OWNING account.
    private func performPrimary(_ row: SessionRow) {
        guard let snapshot = state.selectedSnapshot,
              let session = findSession(row, in: snapshot) else { return }
        let account = account(named: row.accountName)
        Task {
            if row.action == .go {
                await state.goToSession(session, fallbackCwd: session.cwd,
                                        fallbackTitle: row.title, account: account,
                                        workspaceId: row.cmuxWorkspaceId)
            } else {
                await state.resumeSession(session, as: account)
            }
        }
    }

    private func resume(_ row: SessionRow, as account: AccountConfig) {
        guard let snapshot = state.selectedSnapshot,
              let session = findSession(row, in: snapshot) else { return }
        Task { await state.resumeSession(session, as: account) }
    }

    private func account(named name: String) -> AccountConfig {
        state.config.accounts.first { $0.name == name }
            ?? state.config.accounts.first
            ?? AccountConfig(name: "default", configDir: "~/.claude")
    }

    /// Resolves the exact ClaudeSession a row stands for. Account-aware: after a
    /// cross-account resume two sessions share an id under different accounts, so
    /// matching on id alone could return the WRONG account's copy and resume it
    /// under the wrong identity. Match on (id, accountName).
    private func findSession(_ row: SessionRow, in snapshot: ProjectSnapshot) -> ClaudeSession? {
        func match(_ s: ClaudeSession) -> Bool {
            s.id == row.sessionId && s.accountName == row.accountName
        }
        for workspace in snapshot.workspaces {
            if let s = workspace.sessions.first(where: match) { return s }
        }
        for loose in snapshot.loose {
            if let s = loose.sessions.first(where: match) { return s }
        }
        return nil
    }

    // MARK: - Empty state

    private func emptyState(text: String) -> some View {
        VStack(spacing: 8) {
            if state.isScanning {
                ProgressView()
                Text("Scanning project…").font(.headline)
            } else {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No Claude sessions")
                    .font(.headline)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
