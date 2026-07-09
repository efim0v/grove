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
            Text("Status").frame(width: SessionsScreen.statusWidth, alignment: .leading)
            Text("Session").frame(maxWidth: .infinity, alignment: .leading)
            Text("Location").frame(width: SessionsScreen.locationWidth, alignment: .leading)
            Text("Account").frame(width: SessionsScreen.accountWidth, alignment: .leading)
            Text("").frame(width: SessionsScreen.gearWidth)
            Text("").frame(width: SessionsScreen.actionWidth, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    private func sessionRow(_ row: SessionRow, now: Date) -> some View {
        HStack(spacing: 10) {
            statusCell(row, now: now)
                .frame(width: SessionsScreen.statusWidth, alignment: .leading)
            Text(row.title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.location)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: SessionsScreen.locationWidth, alignment: .leading)
            Text(row.accountName)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: SessionsScreen.accountWidth, alignment: .leading)
            Color.clear.frame(width: SessionsScreen.gearWidth)   // no gear for other sessions
            actionCell(row).frame(width: SessionsScreen.actionWidth, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { performResume(row) }
        .help(row.cwd)
    }

    // MARK: - Status cell

    @ViewBuilder
    private func statusCell(_ row: SessionRow, now: Date) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(white: 0.5))   // always resumable / neutral
                .frame(width: 7, height: 7)
            Text("resumable")
                .foregroundStyle(.secondary)
            Text(relativeAge(row.lastActivity, now: now))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Action cell

    @ViewBuilder
    private func actionCell(_ row: SessionRow) -> some View {
        HStack(spacing: 4) {
            Text("Resume")
                .font(.callout)
                .foregroundStyle(Palette.primary)
            resumeAsMenu(row)
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
