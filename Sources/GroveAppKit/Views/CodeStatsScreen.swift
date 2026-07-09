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

    /// Whether the Totals hero discloses its breakdown (code/data split + line kinds). The
    /// chevron next to the hero toggles it; expanded by default so the breakdown shows.
    @State private var totalsExpanded = true

    /// Memoizes the subset re-aggregation (used only when some repos are excluded). A reference
    /// type so writing it inside `body` does NOT itself trigger a re-render (it's not observed),
    /// keyed on (project, exclusion set, scan time) so it recomputes when any of those change
    /// but NOT on a hover tick (which leaves all three identical).
    private final class SubsetAggCache {
        var projectID: UUID?
        var excluded: Set<String> = []
        var signature: Date?
        var value: ProjectGitStats?
    }
    @State private var subsetCache = SubsetAggCache()

    /// The cached subset aggregate (see `SubsetAggCache`). Recomputes via `GitStatsService`
    /// only when the cache key changes; returns the cached `ProjectGitStats` otherwise.
    private func subsetAggregate(_ repos: [RepoStats], excluded: Set<String>,
                                 signature: Date) -> ProjectGitStats {
        if subsetCache.projectID == selectedProjectID, subsetCache.excluded == excluded,
           subsetCache.signature == signature, let value = subsetCache.value {
            return value
        }
        let value = GitStatsService.aggregate(repos, now: .now)
        subsetCache.projectID = selectedProjectID
        subsetCache.excluded = excluded
        subsetCache.signature = signature
        subsetCache.value = value
        return value
    }

    /// Memoizes `stackedRepoSeries` (365-day stacked cumulative chart). Keyed on
    /// `(projectID, scope, scannedAt, metric)` so hover ticks — which leave all four
    /// identical — never recompute the O(365 × repos) series.
    @State private var seriesCache = SeriesCache()

    /// Memoizes `repoCells` (the per-repo delta cards). Keyed on
    /// `(projectID, scope, scannedAt, period)`. A period change is the only user action
    /// that needs a recompute; hover ticks don't.
    @State private var repoCellsCache = RepoCellsCache()

    /// Stable `Date` anchor captured once when the selected project changes (or on
    /// first appear). Used as the `now` argument to `stackedRepoSeries` and `repoCells`
    /// so the memo keys stay identical across render ticks (including hover ticks). The
    /// chart's 365-day window doesn't need sub-render freshness — a stable anchor per
    /// scan is correct and sufficient.
    @State private var anchorNow: Date = .now

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

    /// Repositories EXCLUDED from every stats block by the persistent repo+branch panel
    /// (empty == all repos counted, the default). The included set (all repos minus this)
    /// drives the Totals, Languages, growth chart, deltas, and per-repo blocks: when it's a
    /// strict subset, the screen re-aggregates the included repos with
    /// `GitStatsService.aggregate`; when it's everything, it uses the precomputed project
    /// aggregate untouched. The panel never lets the last repo be unchecked, so this can
    /// never blank the screen. Stale names from a previous project simply don't match.
    @State private var excludedRepos: Set<String> = []

    /// Whether the repo+branch scoping panel (the per-repo checkboxes + branch switchers) is
    /// disclosed. Hidden by default so the controls strip is just the period row; the
    /// "Repositories" text button on the LEFT of that row toggles it, revealing the panel
    /// beneath. View-local UI state only — it never affects scoping (that's `excludedRepos`).
    @State private var showRepoPanel = false

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
            excludedRepos = []
            anchorNow = .now          // capture a fresh anchor before the scan starts
            await state.refreshCodeStats(projectID: id)
            anchorNow = .now          // refresh anchor after the scan so bars are up to date
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
        // Every block scopes to the INCLUDED repos (the panel's checked set == all repos
        // minus `excludedRepos`): the Totals headline + Languages bars read the scoped
        // aggregate, the deltas read the scoped history, the per-repo blocks + growth chart
        // read the scoped list. When every repo is included (the default) we use the
        // precomputed project aggregate as-is; when it's a strict subset we re-aggregate the
        // included repos with the same summing the scan uses, so the headline/chart reflect
        // exactly the chosen repos. The shared controls strip (the persistent repo+branch
        // panel + period) sits ABOVE the first card as a plain row, not a glassCard.
        let repos = state.repoStats[selectedProjectID ?? UUID()] ?? []
        // Exclusion is keyed by repoPath (unique) — leaf repoNames can collide across a
        // multi-repo project, which would let one checkbox toggle two repos.
        let included = repos.filter { !excludedRepos.contains($0.repoPath) }
        let scopedRepos = included.isEmpty ? repos : included    // never blank
        let isSubset = scopedRepos.count != repos.count
        // The subset re-aggregation is O(days×repos); a hover sweep re-evaluates this body once
        // per crossed bar, so memoize it (keyed on project + exclusion + scan time) instead of
        // re-summing every tick. The default/unfiltered path never aggregates here.
        let subsetAgg = isSubset
            ? subsetAggregate(scopedRepos, excluded: excludedRepos, signature: stats.scannedAt)
            : nil
        let scopedStats = subsetAgg?.aggregate ?? stats
        let scopedHistory = subsetAgg?.aggregateHistory ?? history
        let cards = VStack(spacing: 8) {
            let cacheID = selectedProjectID ?? UUID()
            let cacheScannedAt = scopedStats.scannedAt
            let cacheScope = Set(scopedRepos.map(\.repoPath))
            sharedControlsStrip(repos: repos)
            totalsCard(stats: scopedStats, scopedHistory: scopedHistory)
            growthCard(repos: scopedRepos, projectID: cacheID, scope: cacheScope,
                       scannedAt: cacheScannedAt)
            reposCard(repos: scopedRepos, projectID: cacheID, scope: cacheScope,
                      scannedAt: cacheScannedAt)
            languageCard(stats: scopedStats)
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
        // spacing 14 separates the period row from the repo panel; the .padding(.bottom, 6)
        // below adds to the cards VStack's uniform 8 (≈14) so the panel reads as its own
        // section, distinct from both the period row above and the Totals card beneath.
        VStack(alignment: .leading, spacing: 14) {
            // Top row: the repo-panel toggle (left), then the period selector + settings gear
            // (right). The repo+branch scoping panel is disclosed on demand from the toggle
            // rather than always-visible, so the strip is just this row by default.
            HStack(spacing: 8) {
                // Discloses the repo+branch panel below. Reuses the Repositories card's icon
                // so it reads as "repositories"; the chevron rotates 90° when open. Disabled
                // when there are no repos to scope.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showRepoPanel.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "shippingbox")
                            .font(.caption)
                        Text("Repositories")
                            .font(.caption)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showRepoPanel ? 90 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(repos.isEmpty)
                .help(showRepoPanel ? "Hide repositories" : "Show repositories — scope & branch")
                Spacer(minLength: 0)
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
            // The repo+branch panel: hidden by default, disclosed by the toggle above. No
            // surface/backdrop. Each row picks whether the repo counts (checkbox) and which
            // branch it's scanned on. Gated here so the spacing-14 VStack collapses to just
            // the period row when hidden (no empty gap).
            if showRepoPanel {
                repoBranchPanel(repos: repos)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    /// The persistent repo+branch panel — the always-visible settings that scope EVERY
    /// block below. No surface/backdrop: it's a plain column of rows sitting under the
    /// period row. Each row is one repo: a checkbox toggling whether it counts toward the
    /// Totals/Languages/chart/deltas (multi-repo projects only — there's nothing to scope
    /// with one repo), the repo name, and the branch switcher (moved here out of the
    /// Repositories card so all per-repo scoping lives in one place). The panel never lets
    /// the last included repo be unchecked, so the stats can't go blank.
    @ViewBuilder
    private func repoBranchPanel(repos: [RepoStats]) -> some View {
        let multi = repos.count > 1
        VStack(spacing: 6) {
            ForEach(repos, id: \.repoPath) { repo in
                let included = !excludedRepos.contains(repo.repoPath)
                HStack(spacing: 8) {
                    if multi {
                        Button {
                            // Count the CURRENTLY-present included repos (a stale excluded path
                            // from a vanished repo mustn't block a valid toggle).
                            let includedCount = repos.filter { !excludedRepos.contains($0.repoPath) }.count
                            if included {
                                // Keep at least one repo counted — never blank the screen.
                                if includedCount > 1 { excludedRepos.insert(repo.repoPath) }
                            } else {
                                excludedRepos.remove(repo.repoPath)
                            }
                        } label: {
                            Image(systemName: included ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13))
                                .foregroundStyle(included ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(included ? "Exclude from totals" : "Include in totals")
                    }
                    Text(repo.repoName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(included ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    panelBranchSwitcher(repo)
                }
                // Frame each repo as its own row so the repo↔branch pairing reads as a unit
                // (same field radius as the branch chip / stat block → one chip family).
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous)
                        .fill(.white.opacity(0.04))
                )
            }
        }
    }

    /// The per-repo branch switcher inside the panel: picks which branch the repo is scanned
    /// on (writes `setStatsBranch`, which persists + rescans). The chip shows the effective
    /// branch — the pending override if the user just picked one, else the scanned default,
    /// so the label updates immediately rather than waiting for the rescan. `Menu` is
    /// AppKit-backed and draws an ERROR PLACEHOLDER under `ImageRenderer`, so the snapshot
    /// path renders the chip label alone; the dropdown is live-only anyway.
    @ViewBuilder
    private func panelBranchSwitcher(_ repo: RepoStats) -> some View {
        let effective = state.selectedStatsBranchByRepo[repo.repoPath] ?? repo.defaultBranch
        if isSnapshotRender {
            branchChipLabel(effective)
        } else {
            Menu {
                let branches = state.branchesByRepo[repo.repoPath] ?? [repo.defaultBranch]
                ForEach(branches, id: \.self) { branch in
                    Button(branch) {
                        if let id = selectedProjectID {
                            state.setStatsBranch(projectID: id, repoPath: repo.repoPath,
                                                 branch: branch)
                        }
                    }
                }
            } label: {
                branchChipLabel(effective)
            }
            // `.borderlessButton` draws its OWN system disclosure indicator that
            // `.menuIndicator(.hidden)` does NOT reliably suppress on macOS — it leaks and
            // renders to the LEFT of / overlapping the label, so the chip looked like
            // [▾][branch][▾]. `.menuStyle(.button)` HONORS `.menuIndicator(.hidden)`, leaving
            // only the chevron we draw inside `branchChipLabel` (after the branch name);
            // `.buttonStyle(.plain)` strips the button chrome so the bare capsule still shows.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// The branch chip (a Menu label): the effective branch in a subtle capsule with a
    /// downward chevron AFTER the branch name so it reads as a dropdown. The chevron lives in
    /// this shared label (Text THEN chevron), so the visible order is always
    /// [branch name][▾] in BOTH the live Menu and the snapshot fallback. The live Menu uses
    /// `.menuStyle(.button)` + `.menuIndicator(.hidden)` (NOT `.borderlessButton`, whose
    /// system indicator ignores `.menuIndicator(.hidden)` and leaks a stray leading chevron),
    /// so this label's chevron is the ONLY one drawn — never double-drawn, never reversed.
    private func branchChipLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.white.opacity(0.08), in: Capsule())
    }

    // MARK: - Totals header

    private func totalsCard(stats: CodeStats, scopedHistory: [CodeStatsPoint]) -> some View {
        // The HERO is the total line count (all kinds), the headline the user wants raised
        // above the parts. The disclosed breakdown shows TWO partitions of that same total —
        // each carrying its OWN net delta at the number's TOP edge, abbreviated to whole
        // thousands ("+11K"): the language split (code vs data/prose, with file counts) and
        // the line-kind split (code/comment/blank). Both sum to the hero, so the card stays
        // self-consistent. Deltas come from the per-day git history; comment/blank line KINDS
        // have no per-day series, so only the total + the two language groups carry deltas.
        // All values are pure recomputes — switching the period never rescans. `stats`/
        // `scopedHistory` are already scoped to the selected repos by the caller.
        let breakdown = dataProseBreakdown(stats)
        let netByCat = netLinesDeltaByCategory(scopedHistory, period: period, now: .now)
        let totalDelta = compactDeltaTriangle(net: netLinesDelta(scopedHistory, period: period, now: .now))
        return VStack(alignment: .leading, spacing: 10) {
            CardLabel(title: "Totals", systemImage: "chart.pie.fill")
            // Hero row: the big total + "lines" + the disclosure chevron on the left, the
            // period delta pinned to the number's TOP edge on the right (HStack .top).
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { totalsExpanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(groupedThousands(stats.totalLines))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .foregroundStyle(.primary)
                        Text("lines")
                            .font(.caption).foregroundStyle(.secondary)
                        Image(systemName: totalsExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(totalDelta.label)
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(triangleColor(totalDelta.direction))
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                Text("\(groupedThousands(stats.totalFiles)) files")
                    .font(.caption).foregroundStyle(.secondary)
                if state.isStatsScanning { ProgressView().controlSize(.small) }
            }
            if totalsExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    // Language split: code vs data/prose, each with its file count + own delta.
                    HStack(alignment: .top, spacing: 20) {
                        headlineNumber(value: breakdown.codeLinesText,
                                       caption: "code · \(breakdown.codeFilesText) files",
                                       delta: compactDeltaTriangle(net: netByCat.code))
                        headlineNumber(value: breakdown.dataProseLinesText,
                                       caption: "data · \(breakdown.dataProseFilesText) files",
                                       delta: compactDeltaTriangle(net: netByCat.dataProse))
                    }
                    // Line-kind split: the SAME total partitioned by Code / Comment / Blank.
                    // No deltas — git numstat can't classify kinds over time.
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LINE KINDS")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            metric("Code", stats.code, Palette.primary)
                            metric("Comment", stats.comment, Palette.primary.opacity(0.5))
                            metric("Blank", stats.blank, Palette.neutral)
                        }
                    }
                }
                .padding(.top, 2)
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

    /// Map a delta direction to the brand tint: growth blue / decline pink / neutral gray.
    private func triangleColor(_ direction: DeltaTriangle.Direction) -> Color {
        switch direction {
        case .up: return Palette.primary
        case .down: return Palette.negative
        case .flat: return Palette.neutral
        }
    }

    /// One Totals language-group column (code / data): a prominent number with its period
    /// net delta pinned to the value's TOP edge (HStack `.top`) — a superscript at the top-
    /// right, tinted blue ▲ when it grew, pink ▼ when it shrank — over a "<label> · N files"
    /// caption. The delta is the compact whole-K form, matching the hero above.
    private func headlineNumber(value: String, caption: String, delta: DeltaTriangle) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 5) {
                Text(value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(delta.label)
                    .font(.caption2.weight(.semibold))
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

    /// One LINE-KINDS chip: a color dot + kind label + grouped-thousands count.
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
    private func reposCard(repos: [RepoStats], projectID: UUID, scope: Set<String>,
                           scannedAt: Date) -> some View {
        if !repos.isEmpty {
            // repoCells is O(repos × period-scan) — memoize so hover ticks don't recompute.
            let cards = repoCellsCache.cells(
                projectID: projectID, scope: scope, scannedAt: scannedAt,
                period: period, now: anchorNow, repos: repos
            ) { r, n in repoCells(r, period: period, now: n) }
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
    private let yAxisGutterWidth: CGFloat = 26
    /// Height of the X-axis month-label strip drawn under the bars.
    private let monthLabelStripHeight: CGFloat = 14

    private func growthCard(repos: [RepoStats], projectID: UUID, scope: Set<String>,
                            scannedAt: Date) -> some View {
        // stackedRepoSeries is O(365 × repos) — memoize so hover ticks don't recompute.
        let bars = seriesCache.bars(
            projectID: projectID, scope: scope, scannedAt: scannedAt,
            metric: growthMetric, now: anchorNow, repos: repos
        ) { r, n in stackedRepoSeries(r, daysBack: stackedBarMaxDaysBack, metric: growthMetric, now: n) }
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
            // The chart sits directly under the title now — the readout moved INTO the
            // merged stat block below the chart, so hovering no longer grows this card.
            if !hasCode {
                Text("No code history in this window yet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: growthChartHeight, alignment: .leading)
            } else {
                // Left gutter (Y tick labels) + the gridlined bar plot. Gridlines + labels
                // render in BOTH paths (pure geometry); only the hover tooltip is live-only.
                HStack(alignment: .top, spacing: 4) {
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
                // ONE rounded stat block = the merged readout + legend. It always lists
                // every repo (constant row set → constant card height) and shows each repo's
                // value for the focused day: today by default, the hovered/tapped bar on hover.
                // It sits INSET within the card content (not full-bleed) so it reads as a
                // narrower, contained panel under the wider chart.
                statBlock(bars, repos: repos, colors: colors)
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

    /// The merged readout + legend: ONE rounded block below the chart. A header line shows the
    /// FOCUSED day's date + total (hovered ?? tapped ?? today — so the default is today and
    /// hover updates it in place), then a fixed two-column grid of EVERY included repo (sorted),
    /// each with its line count for that day. The row set is the full repo list — NOT the day's
    /// segment subset — so the block's height is structurally constant across hover / no-hover /
    /// any day (a repo with no code that day shows a dimmed "—" rather than dropping a row). It
    /// uses no Menu/hover/scroll, so it renders identically in the snapshot path (focused ==
    /// today). This replaces both the old hover-growing readout and the separate bottom legend.
    private func statBlock(_ bars: [StackedDayBar], repos: [RepoStats],
                           colors: [String: Color]) -> some View {
        // Sorted by name for stable order, but keyed by repoPath (unique) so two repos with the
        // same leaf name don't collide as SwiftUI identities. The per-day lines + color lookups
        // stay keyed by repoName (the chart segments' key).
        let sortedRepos = repos.sorted { $0.repoName < $1.repoName }
        let focused = (hoveredDay ?? selectedDay)
            .flatMap { d in bars.first(where: { $0.date == d }) } ?? bars.last
        // Per-repo line count for the focused day (0 if the repo had no code that day).
        let linesByRepo = Dictionary(
            (focused?.segments ?? []).map { ($0.repoName, $0.lines) }, uniquingKeysWith: { a, _ in a })
        let cols = [GridItem(.flexible(), spacing: 12, alignment: .leading),
                    GridItem(.flexible(), spacing: 12, alignment: .leading)]
        return VStack(alignment: .leading, spacing: 6) {
            Text(focused.map(stackedDayReadout) ?? "No code yet")
                .font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(Palette.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            LazyVGrid(columns: cols, alignment: .leading, spacing: 5) {
                ForEach(sortedRepos, id: \.repoPath) { repo in
                    let value = linesByRepo[repo.repoName] ?? 0
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill((colors[repo.repoName] ?? Palette.primary).opacity(value > 0 ? 1 : 0.4))
                            .frame(width: 8, height: 8)
                        Text(repo.repoName)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(value > 0 ? groupedThousands(value) : "—")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(value > 0 ? Color.secondary : Color.secondary.opacity(0.5))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous)
                .fill(.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: DesignRadius.field, style: .continuous)
                    .strokeBorder(.white.opacity(0.07)))
        )
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
            ScrollView(.horizontal, showsIndicators: false) {
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
