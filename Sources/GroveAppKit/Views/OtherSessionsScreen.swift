import SwiftUI
import GroveCore

/// "Other sessions" bucket — sessions discovered disk-wide whose cwd matches
/// no configured project. Shown at `.otherSessions` route; backs out to `.projects`.
/// Uses the same session-row table + resume machinery as SessionsScreen.
struct OtherSessionsScreen: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            BackButton { state.goBack() }
            Text("Other Sessions")
                .font(.headline)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let rows = buildOtherSessionRows(sessions: state.otherSessions)
        if rows.isEmpty {
            emptyState
        } else if isSnapshotRender {
            table(rows: rows, now: Date())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView { table(rows: rows, now: Date()) }
        }
    }

    // MARK: - Table

    private func table(rows: [SessionRow], now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                sessionRow(row, now: now)
                if index < rows.count - 1 { Divider().opacity(0.4) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Same multi-line card as the Claude tab; these rows are always resumable
    /// (no live process, no gear), so the trailing slot is just Resume + menus.
    private func sessionRow(_ row: SessionRow, now: Date) -> some View {
        SessionCard(row: row, now: now) {
            actionCell(row)
        }
        .contentShape(Rectangle())
        .onTapGesture { performResume(row) }
        .help(row.cwd)
    }

    // MARK: - Action cell

    @ViewBuilder
    private func actionCell(_ row: SessionRow) -> some View {
        HStack(spacing: 4) {
            Text("Resume")
                .font(.callout)
                .foregroundStyle(Palette.primary)
            if let account = state.config.accounts.first(where: { $0.name == row.accountName }),
               !isSnapshotRender,
               AppState.canShareAcrossAccounts(account: account, canonicalDir: state.canonicalDir) {
                shareButton(row: row, account: account)
            }
            migrateToMenu(row)
            resumeAsMenu(row)
        }
    }

    /// "Share" button — adopts the session into the canonical store so it is
    /// visible from every linked account. Only shown for non-default-account rows.
    private func shareButton(row: SessionRow, account: AccountConfig) -> some View {
        Button {
            guard let session = findSession(row) else { return }
            Task { await state.adoptSession(cwd: session.cwd, sessionId: session.id, account: account) }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 11))
                .foregroundStyle(Palette.primary)
        }
        .buttonStyle(.plain)
        .help("Share across accounts — makes this session visible under every linked account")
    }

    /// "Migrate to account…" menu — copies the full session footprint (transcript +
    /// aux + tasks + settings keys + plugins) to another account. Non-destructive.
    /// Only shown when ≥1 other account exists. Snapshot-safe: a static lookalike offscreen.
    @ViewBuilder
    private func migrateToMenu(_ row: SessionRow) -> some View {
        let sourceAccount = state.config.accounts.first { $0.name == row.accountName }
            ?? state.config.accounts.first
            ?? AccountConfig(name: "default", configDir: "~/.claude")
        let others = state.config.accounts.filter { $0.name != row.accountName }
        if !others.isEmpty {
            if isSnapshotRender {
                Image(systemName: "tray.and.arrow.up")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(others, id: \.name) { targetAccount in
                        Button("Migrate to \(targetAccount.name)") {
                            let cwd = row.cwd
                            let sid = row.sessionId
                            let src = sourceAccount
                            let dst = targetAccount
                            Task { await state.migrateSession(cwd: cwd, sessionId: sid,
                                                              from: src, to: dst) }
                        }
                    }
                } label: {
                    Image(systemName: "tray.and.arrow.up")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.primary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Migrate this session (data + config + plugins/hooks) to another account — full copy")
            }
        }
    }

    @ViewBuilder
    private func resumeAsMenu(_ row: SessionRow) -> some View {
        let reachable = Set(row.accounts)
        let everyOther = state.config.accounts.map(\.name)
        let candidateNames = Array(Set(everyOther).union(reachable))
            .filter { $0 != row.accountName }
            .sorted()
        let others = candidateNames.compactMap { name in
            state.config.accounts.first { $0.name == name }
        }
        if !others.isEmpty {
            if isSnapshotRender {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(others, id: \.name) { account in
                        Button("Resume as \(account.name)") {
                            resumeOther(row, as: account)
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

    private func performResume(_ row: SessionRow) {
        guard let session = findSession(row) else { return }
        let account = state.config.accounts.first { $0.name == row.accountName }
            ?? state.config.accounts.first
            ?? AccountConfig(name: "default", configDir: "~/.claude")
        Task { await state.resumeSession(session, as: account) }
    }

    private func resumeOther(_ row: SessionRow, as account: AccountConfig) {
        guard let session = findSession(row) else { return }
        Task { await state.resumeSession(session, as: account) }
    }

    private func findSession(_ row: SessionRow) -> ClaudeSession? {
        state.otherSessions.first { $0.id == row.sessionId && $0.cwd == row.cwd }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No other sessions")
                .font(.headline)
            Text("Sessions under configured project paths appear in their project's Claude tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
