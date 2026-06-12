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

/// Accounts screen (route .accounts, spec §6.3): back header, identity rows
/// (email · organization · tier via the injectable identity provider),
/// live/recent-session usage aggregated across ALL loaded snapshots with a
/// workspace -> project drill-down, "Add & log in" (config + cmux login
/// workspace) and config-only Remove.
struct AccountsScreen: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    @Environment(\.claudeIdentityProvider) private var identityProvider

    @State private var newAccountName = ""
    @State private var expandedAccounts: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            cardList
        }
        .onAppear {
            guard !isSnapshotRender else { return }
            state.verifySharedStore()
        }
    }

    private var header: some View {
        ScopeHeader(title: "Accounts",
                    aggregate: state.aggregateRemaining(window: .fiveHour, now: Date()),
                    onBack: { state.goBack() })
    }

    @ViewBuilder private var cardList: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            ForEach(state.config.accounts, id: \.name) { account in
                accountCard(account)
            }
            addRow
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)

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
                sharedStoreControl(account)
                monitorControl(account)
                rootDirControl(account)
                Button("Remove") {
                    state.removeAccount(name: account.name)
                }
                .controlSize(.small)
                .help("Removes the account from Grove's config only — \(account.configDir) is untouched")
            }
            limitBars(account)
            usageTable(account)
            if isExpanded && !usage.entries.isEmpty {
                Divider()
                drillDown(usage)
            }
            if isExpanded {
                sessionCards(account)
            }
            Text(account.configDir)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .glassCard()
    }

    /// Reveals the account's config dir in Finder. Snapshot-safe: a Button is
    /// AppKit-backed and draws offscreen, so render a plain Image in snapshot mode.
    @ViewBuilder
    private func rootDirControl(_ account: AccountConfig) -> some View {
        if isSnapshotRender {
            Image(systemName: "folder").foregroundStyle(.secondary)
        } else {
            Button { state.openConfigDir(account) } label: { Image(systemName: "folder") }
                .controlSize(.small)
                .help("Reveal \(account.configDir) in Finder")
        }
    }

    /// Monitoring toggle: a green "monitoring" label + "Stop" when active, else a
    /// "Monitor" button. Snapshot-safe plain-label fallback for the buttons.
    @ViewBuilder
    private func monitorControl(_ account: AccountConfig) -> some View {
        if account.monitoring {
            HStack(spacing: 4) {
                Label("monitoring", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption2).foregroundStyle(.green).labelStyle(.titleAndIcon)
                if isSnapshotRender {
                    Text("Stop").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("Stop") { state.disableMonitoring(account) }
                        .controlSize(.small)
                        .help("Restores the original statusline command")
                }
            }
        } else if isSnapshotRender {
            Text("Monitor").font(.caption2).foregroundStyle(Color.accentColor)
        } else {
            Button("Monitor") { state.installMonitoring(account) }
                .controlSize(.small)
                .help("Installs Grove's statusline wrapper to capture usage")
        }
    }

    private func identityLine(_ account: AccountConfig) -> some View {
        Group {
            if let identity = identityProvider(account) {
                // FIX I2: prefer the CANONICAL organizationRateLimitTier (the namespace
                // RateLimitModel.tierWeights keys on) so the card's tier matches the
                // weight table; fall back to the legacy `tier` (userRateLimitTier).
                let tier = identity.organizationRateLimitTier ?? identity.tier
                Text([identity.email, identity.organization, tier]
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

    // MARK: - Limit bars (5h / 7d) from the most-recent capture snapshot

    /// Two limit bars (5-hour, 7-day) sourced from the most-recently captured
    /// snapshot for this account; a hint to enable Monitoring when none exists.
    @ViewBuilder
    private func limitBars(_ account: AccountConfig) -> some View {
        let snapshots = state.snapshotsByAccount[account.name] ?? []
        if let latest = snapshots.max(by: { ($0.capturedAt ?? .distantPast) < ($1.capturedAt ?? .distantPast) }) {
            VStack(alignment: .leading, spacing: 4) {
                if let five = latest.fiveHour {
                    limitBarRow(title: "5h", window: five)
                }
                if let seven = latest.sevenDay {
                    limitBarRow(title: "7d", window: seven)
                }
                if latest.fiveHour == nil && latest.sevenDay == nil {
                    Text("no rate-limit data in last capture")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 2)
        } else {
            Text("no recent capture — enable Monitoring")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    private func limitBarRow(title: String, window: CapturedWindow) -> some View {
        let bar = LimitBar(usedPercentage: window.usedPercentage,
                           resetsAt: window.resetsAt, now: Date())
        return HStack(spacing: 6) {
            Text(title)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor(bar.level))
                        .frame(width: geo.size.width * min(1, max(0, bar.usedPercentage / 100)))
                }
            }
            .frame(height: 6)
            Text("\(Int(bar.usedPercentage.rounded()))%")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            if !bar.resetCaption.isEmpty {
                Text(bar.resetCaption)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func barColor(_ level: CapacityLevel) -> Color {
        switch level {
        case .plenty: return .green
        case .tight: return .orange
        case .critical: return .red
        case .noData: return .secondary
        }
    }

    // MARK: - today / month token+cost table + model breakdown

    /// today / this-month token+cost table plus a model-share breakdown, sourced
    /// from UsageAnalytics. Renders nothing until the first usage refresh populates
    /// `usageByAccount`.
    @ViewBuilder
    private func usageTable(_ account: AccountConfig) -> some View {
        if let analytics = state.usageByAccount[account.name] {
            VStack(alignment: .leading, spacing: 3) {
                usageRow(label: "today", totals: analytics.today)
                usageRow(label: "month", totals: analytics.thisMonth)
                modelBreakdownRow(analytics)
                if !analytics.unpricedModels.isEmpty {
                    Text("unpriced: \(analytics.unpricedModels.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 2)
        }
    }

    private func usageRow(label: String, totals: UsageTotals) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text("\(compactTokens(totals.inputTokens + totals.outputTokens)) tok")
                .font(.caption2).foregroundStyle(.secondary)
            Text(formatUSD(totals.cost))
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func modelBreakdownRow(_ analytics: AccountUsageAnalytics) -> some View {
        // Account-wide token share per model: sum every session's per-model totals.
        var tokensByModel: [String: Int] = [:]
        for session in analytics.sessions.values {
            for (model, tokens) in session.modelBreakdown {
                tokensByModel[model, default: 0] += tokens
            }
        }
        let percentages = modelBreakdownPercentages(tokensByModel)
        return Group {
            if !percentages.isEmpty {
                Text(percentages.sorted { $0.value > $1.value }
                        .map { "\($0.key) \(Int($0.value.rounded()))%" }
                        .joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                EmptyView()
            }
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

    /// "Link to shared store" for a non-canonical, non-shared account; a static
    /// "shared"/"canonical" label otherwise. Snapshot-safe: a Button is AppKit-
    /// backed and draws offscreen, so render a plain label in snapshot mode.
    @ViewBuilder
    private func sharedStoreControl(_ account: AccountConfig) -> some View {
        let isCanonical = expandTilde(account.configDir) == NSHomeDirectory() + "/.claude"
        if isCanonical {
            Label("canonical", systemImage: "star.fill")
                .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
        } else if account.sharedStore {
            Label("shared", systemImage: "link")
                .font(.caption2).foregroundStyle(.green).labelStyle(.titleAndIcon)
        } else if isSnapshotRender {
            Text("Link").font(.caption2).foregroundStyle(Color.accentColor)
        } else {
            Button("Link to shared store") { state.linkAccount(account) }
                .controlSize(.small)
                .help("Symlink this account's session stores into the default ~/.claude store")
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

    // MARK: - Per-session cards (spec §C.5/C.6)

    /// One session's resolved view-model: the ClaudeSession (for Resume/Relaunch),
    /// its UsageAnalytics rollup (tokens/cost/model breakdown), the latest capture
    /// snapshot (context %, effort, captured model) and whether a process is live.
    private struct SessionCardModel: Identifiable {
        let session: ClaudeSession
        let usage: SessionUsage?
        let capture: UsageSnapshot?
        let isLive: Bool
        var id: String { session.id }
    }

    /// All of this account's sessions across every loaded snapshot, deduped by
    /// sessionId (most-recent activity first), each joined to its analytics rollup,
    /// latest capture, and live-process status.
    private func sessionCardModels(_ account: AccountConfig) -> [SessionCardModel] {
        var byId: [String: ClaudeSession] = [:]
        var liveIds: Set<String> = []
        for snapshot in state.snapshots.values {
            for workspace in snapshot.workspaces {
                for s in workspace.sessions where s.accountName == account.name { byId[s.id] = s }
                for p in workspace.liveProcesses where p.accountName == account.name { liveIds.insert(p.sessionId) }
            }
            for loose in snapshot.loose {
                for s in loose.sessions where s.accountName == account.name { byId[s.id] = s }
                for p in loose.liveProcesses where p.accountName == account.name { liveIds.insert(p.sessionId) }
            }
        }
        let analytics = state.usageByAccount[account.name]
        // Latest capture per sessionId (snapshotsByAccount may hold several over time).
        var latestCapture: [String: UsageSnapshot] = [:]
        for snap in state.snapshotsByAccount[account.name] ?? [] {
            let existing = latestCapture[snap.sessionId]?.capturedAt ?? .distantPast
            if (snap.capturedAt ?? .distantPast) >= existing { latestCapture[snap.sessionId] = snap }
        }
        return byId.values
            .map { SessionCardModel(session: $0, usage: analytics?.sessions[$0.id],
                                    capture: latestCapture[$0.id], isLive: liveIds.contains($0.id)) }
            .sorted { $0.session.lastActivity > $1.session.lastActivity }
    }

    @ViewBuilder
    private func sessionCards(_ account: AccountConfig) -> some View {
        let models = sessionCardModels(account)
        if !models.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Sessions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(models) { model in
                    sessionCard(model, account: account)
                }
                Text("A running process can't be re-modeled — relaunch applies the new model.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sessionCard(_ model: SessionCardModel, account: AccountConfig) -> some View {
        let session = model.session
        let project = state.owningProject(forCwd: session.cwd)
        let displayModel = model.capture?.modelDisplayName ?? model.capture?.modelId
            ?? dominantModel(model.usage)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if model.isLive {
                    Label("live", systemImage: "circle.fill")
                        .font(.caption2).foregroundStyle(.green).labelStyle(.titleAndIcon)
                }
                Text(session.title ?? (session.cwd as NSString).lastPathComponent)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(relativeActivity(model))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            sessionStatsRow(model, displayModel: displayModel)
            sessionControls(model, account: account, project: project, displayModel: displayModel)
        }
        .padding(8)
        .background(.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous))
    }

    private func sessionStatsRow(_ model: SessionCardModel, displayModel: String?) -> some View {
        HStack(spacing: 8) {
            if let usage = model.usage {
                Text("in \(compactTokens(usage.inputTokens)) · out \(compactTokens(usage.outputTokens))")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(formatUSD(usage.cost))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let pct = model.capture?.contextUsedPercentage {
                Text("ctx \(Int(pct.rounded()))%")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let displayModel {
                Text(displayModel)
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            if let effort = model.capture?.effort {
                Text("effort \(effort)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    /// Resume + model/effort default pickers (writing the SESSION's owning project)
    /// + "Relaunch with <model>". The card offers the session's OWN account (V1),
    /// so relaunch routes straight through `relaunchSession`. Snapshot-safe: real
    /// Pickers/Buttons render as error placeholders offscreen, so swap in static
    /// lookalikes when `isSnapshotRender`.
    @ViewBuilder
    private func sessionControls(_ model: SessionCardModel, account: AccountConfig,
                                 project: ProjectConfig?, displayModel: String?) -> some View {
        let session = model.session
        HStack(spacing: 6) {
            if isSnapshotRender {
                Text("Resume").font(.caption2).foregroundStyle(Color.accentColor)
                SnapshotPickerLookalike(text: project?.defaultModel ?? "(default)")
                SnapshotPickerLookalike(text: project?.defaultEffort ?? "(default)")
                Text("Relaunch").font(.caption2).foregroundStyle(Color.accentColor)
            } else {
                Button("Resume") {
                    Task { await state.resumeSession(session, as: account) }
                }
                .controlSize(.small)
                if let project {
                    modelPicker(project: project)
                    effortPicker(project: project)
                }
                Button("Relaunch with \(displayModel ?? "model")") {
                    Task {
                        await state.relaunchSession(session, as: account,
                                                    model: project?.defaultModel,
                                                    effort: project?.defaultEffort)
                    }
                }
                .controlSize(.small)
                .help("Resumes under \(account.name) with the project's current model/effort")
            }
            Spacer()
        }
    }

    private func modelPicker(project: ProjectConfig) -> some View {
        Picker("", selection: modelBinding(project)) {
            Text("(default)").tag(String?.none)
            ForEach(ModelPricing.knownModels, id: \.self) { m in
                Text(m).tag(String?.some(m))
            }
        }
        .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
    }

    private func effortPicker(project: ProjectConfig) -> some View {
        Picker("", selection: effortBinding(project)) {
            Text("(default)").tag(String?.none)
            ForEach(["low", "medium", "high"], id: \.self) { e in
                Text(e).tag(String?.some(e))
            }
        }
        .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
    }

    private func modelBinding(_ project: ProjectConfig) -> Binding<String?> {
        Binding(
            get: { (state.config.projects.first { $0.id == project.id })?.defaultModel },
            set: { state.setProjectModel(projectID: project.id, model: $0) })
    }

    private func effortBinding(_ project: ProjectConfig) -> Binding<String?> {
        Binding(
            get: { (state.config.projects.first { $0.id == project.id })?.defaultEffort },
            set: { state.setProjectEffort(projectID: project.id, effort: $0) })
    }

    /// The session's most-used model id (token share), as a fallback when no
    /// capture snapshot recorded a display name.
    private func dominantModel(_ usage: SessionUsage?) -> String? {
        usage?.modelBreakdown.max { $0.value < $1.value }?.key
    }

    private func relativeActivity(_ model: SessionCardModel) -> String {
        let date = model.capture?.capturedAt ?? model.usage?.lastActivity ?? model.session.lastActivity
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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
