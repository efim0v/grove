import SwiftUI
import AppKit
import GroveCore

/// How AccountsScreen resolves an account's identity. Default: the real
/// ClaudeService (reads ~/.claude.json / <configDir>/.claude.json). SnapshotMode
/// overrides this with SnapshotMode.fixtureIdentity so an offscreen render
/// NEVER touches the user's real Claude config.
struct ClaudeIdentityProviderKey: EnvironmentKey {
    static let defaultValue: (AccountConfig) -> AccountIdentity? = { account in
        ClaudeService().identity(account: account)
    }
}

extension EnvironmentValues {
    var claudeIdentityProvider: (AccountConfig) -> AccountIdentity? {
        get { self[ClaudeIdentityProviderKey.self] }
        set { self[ClaudeIdentityProviderKey.self] = newValue }
    }
}

/// Accounts tab (spec §6.3): identity rows (email · organization · tier via
/// the injectable identity provider), live/recent-session usage aggregated
/// across ALL loaded snapshots with a workspace -> project drill-down,
/// "Add & log in" (config + cmux login workspace) and config-only Remove.
struct AccountsScreen: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @Environment(\.claudeIdentityProvider) private var identityProvider

    @State private var newAccountName = ""
    @State private var expandedAccounts: Set<String> = []

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            Text("Accounts")
                .font(.title3.weight(.semibold))
                .padding(.vertical, 10)
            ForEach(state.config.accounts, id: \.name) { account in
                accountCard(account)
            }
            addRow
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)

        // ScrollView content is not rendered offscreen -> plain stack in snapshots.
        if isSnapshotRender {
            content
        } else {
            ScrollView { content }
        }
    }

    // MARK: - Account card

    private func accountCard(_ account: AccountConfig) -> some View {
        let usage = accountUsage(account: account, snapshots: Array(state.snapshots.values))
        let isExpanded = expandedAccounts.contains(account.name) || isSnapshotRender
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name)
                        .font(.callout.weight(.semibold))
                    identityLine(account)
                }
                Spacer()
                usageSummary(usage, account: account)
                Button("Remove") {
                    state.removeAccount(name: account.name)
                }
                .controlSize(.small)
                .help("Removes the account from Grove's config only — \(account.configDir) is untouched")
            }
            if isExpanded && !usage.entries.isEmpty {
                Divider()
                drillDown(usage)
            }
            Text(account.configDir)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .glassCard()
    }

    private func identityLine(_ account: AccountConfig) -> some View {
        Group {
            if let identity = identityProvider(account) {
                Text([identity.email, identity.organization, identity.tier]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                    .foregroundStyle(.secondary)
            } else {
                Text("not logged in")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func usageSummary(_ usage: AccountUsage, account: AccountConfig) -> some View {
        HStack(spacing: 8) {
            if usage.liveCount > 0 {
                Label("\(usage.liveCount) live", systemImage: "circle.fill")
                    .foregroundStyle(.green)
            }
            Label("\(usage.sessionCount) sessions", systemImage: "text.bubble")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        if !usage.entries.isEmpty {
            Button {
                if expandedAccounts.contains(account.name) {
                    expandedAccounts.remove(account.name)
                } else {
                    expandedAccounts.insert(account.name)
                }
            } label: {
                Image(systemName: expandedAccounts.contains(account.name)
                      ? "chevron.down" : "chevron.right")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Where this account is active")
        }
    }

    /// workspace -> project rows (spec §6.3 "раскрытие — где именно").
    private func drillDown(_ usage: AccountUsage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(usage.entries) { entry in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(entry.location)
                        .font(.caption.weight(.medium))
                    Text("· \(entry.project)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if entry.liveCount > 0 {
                        Text("\(entry.liveCount) live")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    Text("\(entry.sessionCount) session\(entry.sessionCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Add account (spec §6.3: name -> config dir -> cmux login workspace)

    private var addRow: some View {
        HStack(spacing: 8) {
            SnapshotSafeTextField(title: "new account name", text: $newAccountName)
                .frame(width: 200)
            Button("Add & log in") { addAccount() }
                .disabled(newAccountName.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("creates ~/.claude-accounts/<name> config and opens a cmux login workspace")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 6)
    }

    private func addAccount() {
        let name = newAccountName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard !state.config.accounts.contains(where: { $0.name == name }) else {
            state.actionError = "account '\(name)' already exists"
            return
        }
        state.addAccount(name: name)
        guard let account = state.config.accounts.first(where: { $0.name == name }) else { return }
        newAccountName = ""
        // Spec §6.3: land the user in a login workspace — `claude` under a fresh
        // CLAUDE_CONFIG_DIR starts its login flow; cwd is simply $HOME.
        Task {
            await state.launchClaude(cwd: NSHomeDirectory(), title: "login: \(name)",
                                     account: account, resume: nil)
        }
    }
}
