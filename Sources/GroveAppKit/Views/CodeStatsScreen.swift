import SwiftUI
import GroveCore

/// Code-stats tab (Stage 5): a per-project cloc-style breakdown rendered from the
/// pure presentation models in CodeStatsPresentation. Gray cards stacked in a
/// scroll: a totals header (big numbers), a language breakdown (horizontal bars +
/// a small per-language table), a cumulative lines-over-time chart stacked by repo
/// (one bar per day, height = total lines across repos, biggest repo at the bottom).
/// Folder/file exclusion now lives on a separate page (StatsSettingsScreen),
/// reached via the gear in the Totals header.
///
/// The scan is lazy: `.task(id:)` triggers `state.refreshCodeStats` whenever the
/// selected project changes, so opening the tab is what kicks off the (off-main)
/// walk — the global 15s refresh never pays for stats. The stacked chart is a
/// hand-drawn SwiftUI bar strip (no Swift Charts), but a `ScrollView`'s content is
/// still not laid out under ImageRenderer, so `isSnapshotRender` swaps in a manual
/// edge-to-edge bars fallback (same landmine the rest of the app handles).
struct CodeStatsScreen: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    /// The window the Totals card + per-repo blocks recompute their deltas over.
    /// Pure client-side recompute from the per-day history — never a re-scan.
    @State private var period: StatsPeriod = .d30

    /// The currently-tapped day in the "Lines over time" stacked chart, if any. Tapping a
    /// bar selects that calendar day → a tooltip above the chart with the day's total
    /// codebase size + a per-repo breakdown; tapping it again clears. Live-only (the
    /// snapshot path renders every bar without a selection).
    @State private var selectedDay: Date?

    /// Which `LanguageStats` field drives the Languages card's bars + sort order, picked
    /// from the in-card metric selector. Default `.code` (the historical behavior).
    @State private var languageMetric: LanguageMetric = .code
    /// Which cumulative quantity the "over time" chart plots (Lines/Code/Data).
    @State private var growthMetric: GrowthMetric = .lines

    /// The repository the shared controls strip scopes ALL stats blocks to, or nil for
    /// "All repos" (the project aggregate). A repo name filters the Totals, Languages,
    /// growth chart, and per-repo blocks down to that one repo via the pure
    /// `filter*ByRepo` helpers. Default nil ("All").
    @State private var selectedRepo: String?

    /// The language whose bar row the cursor is over, if any → a small details overlay
    /// anchored to that row (files / code / comment / blank / %). Live-only: `.onHover`
    /// never fires under ImageRenderer, so snapshots draw the bars with no overlay.
    @State private var hoveredLanguage: String?

    /// The cursor's position WITHIN the hovered language bar row (row-local coordinates),
    /// so the details overlay floats next to the pointer instead of pinning to the row's
    /// trailing edge. Live-only: continuous-hover never fires under ImageRenderer, so the
    /// snapshot path never reads it.
    @State private var hoveredLanguagePosition: CGPoint?

    /// The day the cursor is over in the "Lines over time" strip, if any → a hover tooltip
    /// (date + total + per-repo breakdown). Live-only (continuous-hover never fires
    /// offscreen); falls back to the tap-selected day when nothing is hovered.
    @State private var hoveredDay: Date?

    var body: some View {
        Group {
            if let stats = state.codeStats[selectedProjectID ?? UUID()] {
                content(stats: stats)
            } else if state.isStatsScanning {
                scanningState
            } else {
                emptyState
            }
        }
        .task(id: selectedProjectID) {
            guard let id = selectedProjectID else { return }
            // A day selection is scoped to one project's series; clear it so a stale date
            // from the previous project can't resolve against a same-calendar day in the
            // new one (bar dates are GMT start-of-day). The repo scope is the SAME hazard:
            // repos are matched by name, so a stale name would either silently re-scope the
            // new project to its own same-named repo (a name collision the user never chose)
            // or, when the new project lacks that name, leave the chip on "All repos" while
            // the menu marks nothing active and the stale value keeps filtering. Reset both
            // so every project opens at "All repos".
            selectedDay = nil
            selectedRepo = nil
            await state.refreshCodeStats(projectID: id)
        }
    }

    private var selectedProjectID: UUID? { state.selectedProjectID }

    /// The selected project's per-day aggregate history (oldest first), or empty.
    /// The Totals deltas, growth bars, and selection readout all derive from this.
    private var history: [CodeStatsPoint] {
        state.codeStatsHistory[selectedProjectID ?? UUID()] ?? []
    }

    // MARK: - Populated content

    @ViewBuilder
    private func content(stats: CodeStats) -> some View {
        // Every block scopes to the selected repo (nil == "All"): the Totals headline +
        // Languages bars read the scoped aggregate, the deltas read the scoped history, and
        // the per-repo blocks + growth chart read the scoped repo list. The shared controls
        // strip (repo + period) sits ABOVE the first card as a plain row, not a glassCard.
        let repos = state.repoStats[selectedProjectID ?? UUID()] ?? []
        let scopedStats = filterAggregateByRepo(stats, repos: repos, repoName: selectedRepo)
        let scopedHistory = filterHistoryByRepo(history, repos: repos, repoName: selectedRepo)
        let scopedRepos = filterRepoStats(repos, repoName: selectedRepo)
        let cards = VStack(spacing: 8) {
            sharedControlsStrip(repos: repos)
            totalsCard(stats: scopedStats, scopedHistory: scopedHistory)
            languageCard(stats: scopedStats)
            reposCard(repos: scopedRepos)
            growthCard(repos: scopedRepos)
        }
        .padding(8)
        // ScrollView content isn't rendered offscreen — a plain VStack in snapshots,
        // same trick GraphScreen.graphBody uses.
        if isSnapshotRender {
            cards
        } else {
            // Only the OUTER vertical scroll collapses the search; the inner
            // horizontal chart scroll has its own axis and is left untouched.
            ScrollView { cards.collapsesSearchOnScroll() }
        }
    }

    // MARK: - Shared controls strip (scopes EVERY block below)

    /// A plain row ABOVE the first card (not a glassCard) holding the controls that apply to
    /// ALL stats blocks: the repository selector (scopes Totals/Languages/chart/deltas to one
    /// repo or all) and the period selector (drives every net delta). Both write `@State`
    /// that the pure `filter*ByRepo` helpers + the delta recompute read. The stats-settings
    /// gear lives here too (it was in the Totals header) so the Totals card is pure data.
    private func sharedControlsStrip(repos: [RepoStats]) -> some View {
        HStack(spacing: 8) {
            repoSelector(repos: repos)
            Spacer(minLength: 8)
            periodControl
            // Opens the separate stats-settings page (the directory+file exclusion tree);
            // disabled until a project is selected.
            Button {
                if let id = selectedProjectID { state.open(.statsSettings(id)) }
            } label: {
                Image(systemName: "gear")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(selectedProjectID == nil)
            .help("Stats settings — file tree & exclusions")
        }
        .padding(.horizontal, 4)
    }

    /// The repository scope selector: "All repos" + one entry per repo, writing
    /// `selectedRepo` (nil == All). A `Menu` is AppKit-backed and draws an ERROR PLACEHOLDER
    /// under `ImageRenderer` (same as the branch switcher / `Picker(.segmented)`), so the
    /// snapshot path renders the chip label alone — selection is inherently live-only. The
    /// chip visuals are shared so both paths match. Single-repo projects hide the selector
    /// entirely (nothing to scope).
    @ViewBuilder
    private func repoSelector(repos: [RepoStats]) -> some View {
        if repos.count > 1 {
            let options = repoScopeOptions(repos)
            let current = options.first { $0.name == selectedRepo } ?? options[0]
            if isSnapshotRender {
                repoSelectorChip(current.label)
            } else {
                Menu {
                    ForEach(options) { option in
                        Button {
                            selectedRepo = option.name
                        } label: {
                            if option.name == selectedRepo {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    repoSelectorChip(current.label)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    /// The repo selector's label chip: the active scope in a subtle capsule with a
    /// disclosure chevron, mirroring the branch chip's look so the strip reads as a control.
    private func repoSelectorChip(_ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "shippingbox")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.white.opacity(0.08), in: Capsule())
    }

    // MARK: - Totals header

    private func totalsCard(stats: CodeStats, scopedHistory: [CodeStatsPoint]) -> some View {
        // Both headline numbers (Code / Data·Prose), the file counts, and the per-category
        // deltas are pure recomputes from already-scanned data — switching the period never
        // triggers a git re-scan. Each headline now carries its OWN net delta inline at the
        // value's top-right: how much that category's lines grew (▲, blue) or shrank (▼, pink)
        // over the period, a churn-free per-category state difference (a line churned 5×
        // counts once). The old single combined net line below both headlines is gone. Both
        // `stats` and `scopedHistory` are already scoped to the selected repo by the caller.
        let breakdown = dataProseBreakdown(stats)
        let netByCategory = netLinesDeltaByCategory(scopedHistory, period: period, now: .now)
        // File-count delta isn't derivable from line history client-side, so the file
        // caption stays a plain count (the per-day series carries only lines).
        return VStack(alignment: .leading, spacing: 10) {
            CardLabel(title: "Totals", systemImage: "chart.pie.fill")
            HStack(alignment: .top, spacing: 24) {
                // The headline is the LANGUAGE-GROUP split: total lines of non-data/prose
                // languages ("code") vs data/prose languages ("data"). Distinct axis from
                // the line-kind strip below, hence the "lines · N files" caption (it is
                // total lines of the code-language group, not the code-only line kind).
                headlineNumber(value: breakdown.codeLinesText,
                               caption: "code · \(breakdown.codeFilesText) files",
                               delta: deltaTriangle(net: netByCategory.code))
                headlineNumber(value: breakdown.dataProseLinesText,
                               caption: "data · \(breakdown.dataProseFilesText) files",
                               delta: deltaTriangle(net: netByCategory.dataProse))
            }
            // The LINE-KIND breakdown: every line classified Code / Comment / Blank across
            // ALL languages. A different partition than the headline's language groups (so
            // "Code" here ≠ the "code" headline) — the caption flags the axis.
            VStack(alignment: .leading, spacing: 3) {
                Text("LINE KINDS")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    metric("Code", stats.code, Palette.primary)
                    metric("Comment", stats.comment, Palette.primary.opacity(0.5))
                    metric("Blank", stats.blank, Palette.neutral)
                    if state.isStatsScanning {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard()
    }

    /// The 7d / 30d / 90d / 180d / 360d segmented control. Pure-SwiftUI (Buttons) so it renders
    /// identically live and offscreen — AppKit Picker(.segmented) draws as an error
    /// placeholder under ImageRenderer, and the live-only nature of selection means a
    /// snapshot just shows the current period highlighted.
    private var periodControl: some View {
        HStack(spacing: 0) {
            ForEach(StatsPeriod.allCases) { p in
                let selected = p == period
                Button {
                    period = p
                } label: {
                    Text(p.rawValue)
                        .font(.caption2.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .frame(minWidth: 30)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: DesignRadius.field - 2, style: .continuous)
                                    .fill(Palette.primary.opacity(0.85))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous)
            .strokeBorder(.white.opacity(0.10)))
    }

    /// One headline column: a big number with its per-category net delta inline at the
    /// top-right, plus a caption. The `delta` ▲/▼ is baseline-aligned to the big number so
    /// it reads as a superscript at the value's top-right (blue ▲ when the category grew,
    /// pink ▼ when it shrank, gray ±0 when flat). Each category's own net over the selected
    /// period — the misleading two-sided added/removed churn is long gone.
    private func headlineNumber(value: String, caption: String, delta: DeltaTriangle) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(delta.label)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(triangleColor(delta.direction))
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// Map a delta direction to the brand tint: growth blue / decline pink / neutral gray.
    private func triangleColor(_ direction: DeltaTriangle.Direction) -> Color {
        switch direction {
        case .up: return Palette.primary
        case .down: return Palette.negative
        case .flat: return Palette.neutral
        }
    }

    private func metric(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(groupedThousands(value)).font(.caption.weight(.medium)).monospacedDigit()
        }
    }

    // MARK: - Language breakdown (bars + table)

    private func languageCard(stats: CodeStats) -> some View {
        // The chosen metric drives the bar length AND the sort order — switching it re-scales
        // and re-sorts the distribution (a pure recompute, no re-scan).
        let bars = languageBars(stats, metric: languageMetric)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                CardLabel(title: "Languages",
                          systemImage: "chevron.left.forwardslash.chevron.right")
                Spacer(minLength: 8)
                languageMetricControl
            }
            if bars.isEmpty {
                Text("No source files matched a known language.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // Code languages share the blue ramp (most-saturated first); data/prose
                // languages (Markdown/JSON/YAML/TOML) get a muted neutral tint so the two
                // groups read apart while every language still lists in order.
                let codeRanks = codeRankByLanguage(bars)
                ForEach(bars) { bar in
                    languageBarRow(bar, color: laneColor(for: bar, codeRank: codeRanks[bar.language]))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard()
    }

    /// The Languages metric segmented control (Code / Files / Lines / Comment / Blank).
    /// Pure-SwiftUI Buttons — the same pattern as `periodControl` — so it renders identically
    /// live and offscreen (AppKit `Picker(.segmented)` draws an error placeholder under
    /// ImageRenderer). Writing it re-scales + re-sorts the bars.
    private var languageMetricControl: some View {
        HStack(spacing: 0) {
            ForEach(LanguageMetric.allCases) { m in
                let selected = m == languageMetric
                Button {
                    languageMetric = m
                } label: {
                    Text(m.rawValue)
                        .font(.caption2.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: DesignRadius.field - 2,
                                                 style: .continuous)
                                    .fill(Palette.primary.opacity(0.85))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous)
            .strokeBorder(.white.opacity(0.10)))
    }

    /// Map each CODE language to its rank among code languages only (0-based, in the
    /// already-DESC-by-code bar order). Data/prose languages are absent — they don't
    /// consume blue saturation, so the code ramp stays cohesive regardless of where a
    /// prose row sorts in.
    private func codeRankByLanguage(_ bars: [LanguageBar]) -> [String: Int] {
        var ranks: [String: Int] = [:]
        var next = 0
        for bar in bars where !CodeStatsEngine.isDataProse(bar.language) {
            ranks[bar.language] = next
            next += 1
        }
        return ranks
    }

    /// Bar tint. CODE languages share the on-brand blue ramp, stepped down in opacity by
    /// their code-only rank (floored at 0.35 so a long tail stays legible). DATA/PROSE
    /// languages (Markdown/JSON/YAML/TOML) get a flat muted neutral so they read as a
    /// distinct group rather than competing on the blue axis.
    private func laneColor(for bar: LanguageBar, codeRank: Int?) -> Color {
        if CodeStatsEngine.isDataProse(bar.language) {
            return Palette.neutral.opacity(0.55)
        }
        let rank = codeRank ?? 0
        return Palette.primary.opacity(max(0.35, 1.0 - Double(rank) * 0.12))
    }

    private func languageBarRow(_ bar: LanguageBar, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(bar.language)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(color)
                        // A non-zero language always shows a sliver, like ProgressBar.
                        .frame(width: bar.fraction > 0
                               ? max(geo.size.width * bar.fraction, 4) : 0)
                }
            }
            // Thin bars (~5px) matching the dashboard's ProgressBar for design consistency.
            .frame(height: 5)
            // The trailing number tracks the SELECTED metric (not always code).
            Text(bar.metricText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .contentShape(Rectangle())
        // Live-only hover: continuous-hover never fires under ImageRenderer, so snapshots
        // draw the bars with no overlay. Track the row + the cursor's row-local position so
        // the details tooltip follows the pointer instead of pinning to the row's edge.
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hoveredLanguage = bar.language
                hoveredLanguagePosition = point
            case .ended:
                if hoveredLanguage == bar.language {
                    hoveredLanguage = nil
                    hoveredLanguagePosition = nil
                }
            }
        }
        // The details overlay floats as a tooltip NEXT TO THE CURSOR (anchored to the
        // row-local hover position), gated on the live render so it never appears in
        // snapshots. `.allowsHitTesting(false)` keeps it from stealing the hover.
        .overlay(alignment: .topLeading) {
            if !isSnapshotRender, hoveredLanguage == bar.language,
               let pos = hoveredLanguagePosition {
                languageHoverOverlay(bar)
                    // Offset up-and-right of the pointer so the cursor doesn't cover it; the
                    // overlay's own width is unknown here, so a small lead keeps it readable.
                    .offset(x: pos.x + 12, y: pos.y - 46)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The hover details panel for a language row — the data the old per-language table
    /// carried: files / code / comment / blank, plus the chosen metric's share (%). A small
    /// floating card anchored to the row. Live-only (snapshots never hover).
    private func languageHoverOverlay(_ bar: LanguageBar) -> some View {
        let isData = CodeStatsEngine.isDataProse(bar.language)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(bar.language)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isData ? Palette.neutral : .primary)
                Spacer(minLength: 8)
                Text("\(bar.shareText) of \(languageMetric.rawValue.lowercased())")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                overlayStat("Files", bar.filesText)
                overlayStat("Code", bar.codeText)
                overlayStat("Comment", bar.commentText)
                overlayStat("Blank", bar.blankText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // A dark, near-opaque backdrop so it reads as a floating tooltip lifted off
        // the bars. NOT .regularMaterial — SwiftUI Material recursed in
        // MaterialProviderBox.resolveLayers (stack overflow) resolving its backdrop
        // near the window's nested glass; a flat dark fill can't reach that path.
        .background {
            RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous)
                .fill(Color(white: 0.08).opacity(0.97))
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous)
            .strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .fixedSize()
    }

    /// One label/value pair in the language hover overlay.
    private func overlayStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Per-repo blocks

    /// A compact block per git repo: name, its default branch (read-only chip for now),
    /// total LOC, and its delta over the SAME selected period as the Totals card. Single-
    /// repo projects collapse to one block; multi-repo (e.g. acme.shop's 4) stack
    /// tight inside one card.
    @ViewBuilder
    private func reposCard(repos: [RepoStats]) -> some View {
        if !repos.isEmpty {
            let cards = repoCells(repos, period: period, now: .now)
            // The same stable name→color map the stacked chart's segments + legend use, so
            // a repo's swatch here matches its slice in "Lines over time".
            let colors = repoColorMap(repos)
            VStack(alignment: .leading, spacing: 8) {
                CardLabel(title: repos.count > 1 ? "Repositories" : "Repository",
                          systemImage: "shippingbox")
                VStack(spacing: 6) {
                    ForEach(cards) { card in
                        repoBlock(card, color: colors[card.repoName] ?? Palette.primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .glassCard()
        }
    }

    private func repoBlock(_ card: RepoCard, color: Color) -> some View {
        HStack(spacing: 8) {
            // The repo's legend swatch — matches its segment in the stacked chart.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(card.repoName)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            branchSwitcher(card)
            Spacer(minLength: 8)
            Text(card.totalLinesText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
            Text("lines")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(card.triangle.label)
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(triangleColor(card.triangle.direction))
                .frame(minWidth: 56, alignment: .trailing)
        }
    }

    /// Per-repo branch switcher: a borderless `Menu` whose label is the effective
    /// branch (a capsule chip), listing the repo's local branches (fallback to just
    /// the current one) and rescanning on pick.
    ///
    /// `Menu` is AppKit-backed and draws an ERROR PLACEHOLDER under `ImageRenderer`
    /// (same failure mode as `Picker(.segmented)` and Swift Charts elsewhere in this
    /// screen), so the snapshot path renders the chip label on its own — the dropdown
    /// is inherently live-only anyway. The chip visuals are shared so both paths match.
    @ViewBuilder
    private func branchSwitcher(_ card: RepoCard) -> some View {
        if isSnapshotRender {
            branchChip(card)
        } else {
            Menu {
                let branches = state.branchesByRepo[card.repoPath] ?? [card.defaultBranch]
                ForEach(branches, id: \.self) { branch in
                    Button(branch) {
                        if let id = selectedProjectID {
                            state.setStatsBranch(projectID: id, repoPath: card.repoPath,
                                                 branch: branch)
                        }
                    }
                }
            } label: {
                branchChip(card)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// The branch chip (the Menu's label): the effective branch in a subtle capsule.
    private func branchChip(_ card: RepoCard) -> some View {
        Text(card.defaultBranch)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.white.opacity(0.08), in: Capsule())
    }

    // MARK: - Stacked cumulative chart ("Lines over time")

    /// Lines/Code/Data toggle for the "over time" chart — same segmented style as the
    /// languages metric control. Pure SwiftUI so it renders identically live and offscreen.
    private var growthMetricControl: some View {
        HStack(spacing: 0) {
            ForEach(GrowthMetric.allCases) { m in
                let selected = m == growthMetric
                Button {
                    growthMetric = m
                } label: {
                    Text(m.rawValue)
                        .font(.caption2.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: DesignRadius.field - 2,
                                                 style: .continuous)
                                    .fill(Palette.primary.opacity(0.85))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous)
            .strokeBorder(.white.opacity(0.10)))
    }

    private let growthChartHeight: CGFloat = 120
    /// Each calendar-day bar's slot width (bar + 1px gap). 4pt at ~180 visible days
    /// fills a ~720pt plot — the dense reference look — while the ScrollView lets older
    /// days (back to the 1-year cap) scroll into view.
    private let stackedSlotWidth: CGFloat = 4

    /// A stable repo name → color map for the stacked chart's segments + legend AND the
    /// per-repo blocks' swatches. Repos are ordered by name (the same order `repoCells`
    /// sorts by), so a repo keeps its color everywhere; the hue spreads across the brand
    /// ramp via `repoColor`.
    private func repoColorMap(_ repos: [RepoStats]) -> [String: Color] {
        let names = repos.map(\.repoName).sorted()
        var map: [String: Color] = [:]
        for (i, name) in names.enumerated() {
            map[name] = repoColor(index: i, count: names.count)
        }
        return map
    }

    /// The "Lines over time" card: a DENSE per-day CUMULATIVE codebase-size chart, one thin
    /// bar per calendar day, each STACKED BY REPO — the biggest repo at the bottom, the
    /// smallest on top — with the bar's height proportional to the TOTAL number of lines
    /// across all repos that day. This is the running codebase SIZE ("how many lines REALLY
    /// existed on a given day"), so the strip visibly GROWS left→right as repos accumulate
    /// lines — NOT per-day churn.
    ///
    /// The chart's window is DECOUPLED from the Totals 7d/30d/90d period: the series always
    /// spans the full 1-year cap (`stackedBarMaxDaysBack`) so the strip is genuinely
    /// scrollable, and it opens scrolled to today with ~`stackedDefaultVisibleDays` (6
    /// months) filling the viewport. The Totals/Repos `period` only drives the net delta.
    /// Width of the left Y-axis gutter that holds the tick value labels (0 / 100k / …).
    private let yAxisGutterWidth: CGFloat = 40
    /// Height of the X-axis month-label strip drawn under the bars.
    private let monthLabelStripHeight: CGFloat = 14

    private func growthCard(repos: [RepoStats]) -> some View {
        let bars = stackedRepoSeries(repos, daysBack: stackedBarMaxDaysBack, metric: growthMetric, now: .now)
        let colors = repoColorMap(repos)
        let hasCode = bars.contains { $0.total > 0 }
        // "Nice" Y-axis ticks; the TOP tick (≥ peak) is the shared denominator both the
        // gridlines and the bar heights normalize against, so the tallest bar sits just
        // below the top gridline and the magnitudes read off the left labels.
        let ticks = niceTicks(peak: stackedPeak(bars))
        let topTick = max(ticks.last ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                CardLabel(title: "\(growthMetric.rawValue) over time", systemImage: "chart.bar.fill")
                Spacer(minLength: 8)
                growthMetricControl
            }
            stackedReadout(bars, repoCount: repos.count, colors: colors)
            if !hasCode {
                Text("No code history in this window yet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: growthChartHeight, alignment: .leading)
            } else {
                // Left gutter (Y tick labels) + the gridlined bar plot. Gridlines + labels
                // render in BOTH paths (pure geometry); only the hover tooltip is live-only.
                HStack(alignment: .top, spacing: 6) {
                    yAxisLabels(ticks: ticks, topTick: topTick)
                    ZStack(alignment: .topLeading) {
                        yAxisGridlines(ticks: ticks, topTick: topTick)
                        if isSnapshotRender {
                            // The manual stacked bars draw fine offscreen (Swift-Charts-free);
                            // the snapshot just trims to the most-recent visible window so the
                            // dense chart reads without a horizontal scroller.
                            stackedFallback(bars, colors: colors, topTick: topTick)
                        } else {
                            stackedScroller(bars, colors: colors, topTick: topTick)
                        }
                    }
                }
                stackedLegend(repos, colors: colors)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard()
    }

    /// The left Y-axis gutter: each nice tick's value (compact, e.g. "100k") placed at its
    /// height so magnitudes read off the chart. The bottom row reserves the month-label
    /// strip's height so the gridline 0 lines up with the bars' baseline.
    private func yAxisLabels(ticks: [Int], topTick: Int) -> some View {
        GeometryReader { geo in
            let plotH = max(geo.size.height - monthLabelStripHeight, 1)
            ForEach(ticks, id: \.self) { tick in
                let y = plotH - CGFloat(tick) / CGFloat(topTick) * plotH
                Text(formatCompactTokens(tick))
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: yAxisGutterWidth, alignment: .trailing)
                    .position(x: yAxisGutterWidth / 2, y: y)
            }
        }
        .frame(width: yAxisGutterWidth,
               height: growthChartHeight + monthLabelStripHeight)
    }

    /// Faint horizontal gridlines behind the bars, one per nice tick, normalized against the
    /// top tick (the shared bar denominator) so they align with the bar heights. Spans only
    /// the plot height (above the month-label strip).
    private func yAxisGridlines(ticks: [Int], topTick: Int) -> some View {
        GeometryReader { geo in
            let plotH = growthChartHeight
            ForEach(ticks, id: \.self) { tick in
                let y = plotH - CGFloat(tick) / CGFloat(topTick) * plotH
                Rectangle()
                    .fill(.white.opacity(0.06))
                    .frame(height: 1)
                    .position(x: geo.size.width / 2, y: y)
            }
        }
        .frame(height: growthChartHeight + monthLabelStripHeight, alignment: .top)
        .allowsHitTesting(false)
    }

    /// The readout above the chart: either the HOVERED day (live, cursor → nearest day) or,
    /// failing that, the tapped day's total + per-repo breakdown; otherwise a neutral hint of
    /// how many repos are stacked. The per-repo breakdown renders as small color-coded chips
    /// (matching each repo's stacked-segment color), biggest-first. Tinted blue (the codebase
    /// size axis).
    @ViewBuilder
    private func stackedReadout(_ bars: [StackedDayBar], repoCount: Int,
                                colors: [String: Color]) -> some View {
        // Hover wins over tap so the tooltip tracks the cursor; both fall back to the hint.
        let active = (hoveredDay ?? selectedDay).flatMap { day in
            bars.first(where: { $0.date == day })
        }
        if let bar = active {
            VStack(alignment: .leading, spacing: 2) {
                Text(stackedDayReadout(bar))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !bar.segments.isEmpty {
                    // Per-repo breakdown of that day, biggest-first (segment order), each a
                    // colored chip matching its stacked segment.
                    FlowingLegend(spacing: 10, rowSpacing: 3) {
                        ForEach(bar.segments, id: \.repoName) { seg in
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(colors[seg.repoName] ?? Palette.primary)
                                    .frame(width: 7, height: 7)
                                Text("\(seg.repoName) \(groupedThousands(seg.lines))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        } else {
            Text("\(repoCount) \(repoCount == 1 ? "repo" : "repos") stacked · "
                 + (isSnapshotRender ? "codebase size over time" : "hover or tap a bar for that day’s total"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// A compact wrapping legend mapping each repo to its stacked-chart color. Sorted by
    /// name so it matches the segment/swatch order; truncates long names so it stays 1–2
    /// lines.
    private func stackedLegend(_ repos: [RepoStats], colors: [String: Color]) -> some View {
        let names = repos.map(\.repoName).sorted()
        return FlowingLegend(spacing: 10, rowSpacing: 4) {
            ForEach(names, id: \.self) { name in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(colors[name] ?? Palette.primary)
                        .frame(width: 8, height: 8)
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    /// The live chart: a horizontally-scrollable strip of fixed-width per-day stacked bars.
    /// A `ScrollView(.horizontal)` (rather than a width-fitted Swift Chart) keeps the bar
    /// density crisp and constant — the series spans the full 1-year cap, so ~180 days
    /// (`stackedDefaultVisibleDays` × `stackedSlotWidth` ≈ 720pt) fill the default viewport
    /// and the remaining ~185 older days scroll in. Starts scrolled to the most-recent day.
    /// A tap on any bar selects that day for the tooltip readout; tapping it clears it.
    private func stackedScroller(_ bars: [StackedDayBar], colors: [String: Color],
                                 topTick: Int) -> some View {
        let labels = monthLabelPositions(bars, slotWidth: stackedSlotWidth)
        let stripWidth = CGFloat(bars.count) * stackedSlotWidth
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    // The bars. Heights normalize against the nice top tick (≥ peak) so they
                    // align with the Y gridlines behind them.
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(bars) { bar in
                            stackedBarColumn(bar, peak: topTick, colors: colors)
                                .frame(width: stackedSlotWidth)
                                .id(bar.date)
                                .contentShape(Rectangle())
                                .onTapGesture { toggleDaySelection(bar) }
                        }
                    }
                    .frame(width: stripWidth, height: growthChartHeight, alignment: .bottom)
                    // Continuous hover maps the cursor x → the nearest day index so the
                    // tooltip tracks the cursor. Live-only (never fires under ImageRenderer).
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            let idx = Int(p.x / stackedSlotWidth)
                            if bars.indices.contains(idx) { hoveredDay = bars[idx].date }
                        case .ended:
                            hoveredDay = nil
                        }
                    }
                    // X-axis month labels, one per month boundary, positioned in lockstep with
                    // the bars (same slot width, same scroll offset).
                    monthLabelStrip(labels, width: stripWidth)
                }
            }
            .frame(height: growthChartHeight + monthLabelStripHeight)
            .onAppear { if let last = bars.last { proxy.scrollTo(last.date, anchor: .trailing) } }
        }
    }

    /// The X-axis month-label strip: one short month name per boundary at its day-column x.
    /// `width` matches the bar strip so it scrolls in lockstep inside the same ScrollView.
    private func monthLabelStrip(_ labels: [MonthLabel], width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(cullCloseMonthLabels(labels)) { label in
                Text(label.label)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .alignmentGuide(.leading) { _ in 0 }
                    .offset(x: label.x, y: 2)
            }
        }
        .frame(width: max(width, 1), height: monthLabelStripHeight, alignment: .topLeading)
    }

    /// Drop month labels that would overlap their predecessor — the leading-edge label
    /// (`monthLabelPositions` always emits index 0) can land only a few day-columns before
    /// the first true month boundary, so we suppress any label within `minGap` px of the
    /// previously-kept one. Purely a render concern; the pure helper's positions are intact.
    private func cullCloseMonthLabels(_ labels: [MonthLabel], minGap: CGFloat = 28) -> [MonthLabel] {
        var kept: [MonthLabel] = []
        for label in labels {
            if let last = kept.last, label.x - last.x < minGap {
                // Prefer the true month boundary over the synthetic leading-edge label when
                // they collide: replace a kept index-0 (x == 0) with the real boundary.
                if last.x == 0 { kept[kept.count - 1] = label }
                continue
            }
            kept.append(label)
        }
        return kept
    }

    /// One day's column in the live strip: a bottom-anchored stack of per-repo segments,
    /// BIGGEST repo at the bottom. `bar.segments` is biggest-first; a `VStack` lays its
    /// children top→bottom, so we iterate `reversed()` (smallest first at the top) to put
    /// the biggest at the bottom. The selected day renders full-strength; others muted when
    /// a selection exists. Uses a GeometryReader so segment heights normalize against the
    /// plot box.
    private func stackedBarColumn(_ bar: StackedDayBar, peak: Int,
                                  colors: [String: Color]) -> some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                // reversed(): smallest on top, biggest at the bottom.
                ForEach(Array(bar.segments.enumerated().reversed()), id: \.offset) { _, seg in
                    Rectangle()
                        .fill(segmentFill(seg, on: bar, colors: colors))
                        .frame(width: max(stackedSlotWidth - 1, 1),
                               height: stackedSegmentHeight(lines: seg.lines, peak: peak,
                                                            height: geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, alignment: .bottom)
        }
    }

    /// One segment's tint: the repo's stable color, full-strength when nothing is focused
    /// (no hover, no tap) or this IS the focused day, muted otherwise so the hovered/tapped
    /// bar stands out. Hover takes precedence over tap (matching the readout).
    private func segmentFill(_ seg: StackedSegment, on bar: StackedDayBar,
                             colors: [String: Color]) -> Color {
        let base = colors[seg.repoName] ?? Palette.primary
        let focus = hoveredDay ?? selectedDay
        guard let focus else { return base }
        return focus == bar.date ? base : base.opacity(0.45)
    }

    /// Tap handling: select the tapped day (showing its tooltip), or clear if it was
    /// already selected. Empty (no-code) days clear any selection (nothing to show).
    private func toggleDaySelection(_ bar: StackedDayBar) {
        if selectedDay == bar.date || bar.total == 0 {
            selectedDay = nil
        } else {
            selectedDay = bar.date
        }
    }

    /// Snapshot fallback: a manual stacked-bar render (Swift Charts draw blank under
    /// ImageRenderer, and a ScrollView's content isn't laid out offscreen either, so the
    /// snapshot trims to the most-recent days that fit the card and draws them edge-to-
    /// edge). Selection is live-only, so every bar draws at full strength.
    private func stackedFallback(_ bars: [StackedDayBar], colors: [String: Color],
                                 topTick: Int) -> some View {
        GeometryReader { geo in
            stackedFallbackContent(bars, size: geo.size, colors: colors, topTick: topTick)
        }
        .frame(height: growthChartHeight + monthLabelStripHeight)
    }

    /// The actual stacked rects for `stackedFallback`, against a resolved `size`. Trims to
    /// the most-recent `floor(width / slot)` days so the offscreen strip fills the card
    /// without a scroller, then draws each day as a bottom-up stack of per-repo segments
    /// (biggest at the bottom) proportional to that day's total, normalized against the nice
    /// top tick so the bars align with the gridlines. Month labels for the trimmed window
    /// draw at the bottom edge so the static snapshot also shows the X-axis. Pulled out of
    /// the GeometryReader closure so the geometry math doesn't fight the ViewBuilder.
    private func stackedFallbackContent(_ bars: [StackedDayBar], size: CGSize,
                                        colors: [String: Color], topTick: Int) -> some View {
        let w = size.width, h = max(size.height - monthLabelStripHeight, 1)
        let slot = max(stackedSlotWidth, 1)
        let visibleCount = max(min(bars.count, Int(w / slot)), 1)
        let visible = Array(bars.suffix(visibleCount))
        let barWidth = max(slot - 1, 1)
        // Month labels recomputed over the SAME trimmed window the bars use (and culled so
        // the leading-edge label can't overlap the first real month boundary).
        let labels = cullCloseMonthLabels(monthLabelPositions(visible, slotWidth: slot))
        return ZStack(alignment: .bottomLeading) {
            // Bars, anchored to the plot area above the month-label strip.
            ZStack(alignment: .bottomLeading) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { i, bar in
                    let x = CGFloat(i) * slot
                    // reversed(): smallest on top, biggest at the bottom.
                    VStack(spacing: 0) {
                        ForEach(Array(bar.segments.enumerated().reversed()), id: \.offset) { _, seg in
                            Rectangle()
                                .fill(colors[seg.repoName] ?? Palette.primary)
                                .frame(width: barWidth,
                                       height: stackedSegmentHeight(lines: seg.lines,
                                                                    peak: topTick, height: h))
                        }
                    }
                    .offset(x: x, y: 0)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(height: h, alignment: .bottom)
            .frame(maxHeight: .infinity, alignment: .top)
            // The X-axis month labels at the bottom edge.
            ForEach(labels) { label in
                Text(label.label)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: label.x)
            }
        }
    }

    // MARK: - Loading / empty states

    private var scanningState: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.large)
            Text("Scanning code…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(selectedProjectID == nil
                 ? "No project selected."
                 : "No stats yet — they appear once the scan finishes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A minimal left-to-right wrapping flow `Layout` for the repo legend: places each child
/// at its ideal size, wrapping to a new row when the next child would overflow the
/// proposed width. Deterministic, so it renders identically live and offscreen (unlike a
/// width-driven `ScrollView`, which doesn't lay out under ImageRenderer).
struct FlowingLegend: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0, totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + rowSpacing
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x - bounds.minX + size.width > maxWidth {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
