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
            // new one (bar dates are GMT start-of-day).
            selectedDay = nil
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
        let cards = VStack(spacing: 8) {
            totalsCard(stats: stats)
            languageCard(stats: stats)
            reposCard()
            growthCard()
        }
        .padding(8)
        // ScrollView content isn't rendered offscreen — a plain VStack in snapshots,
        // same trick GraphScreen.graphBody uses.
        if isSnapshotRender {
            cards
        } else {
            ScrollView { cards }
        }
    }

    // MARK: - Totals header

    private func totalsCard(stats: CodeStats) -> some View {
        // Both headline numbers (Code / Data·Prose), the file counts, and the period delta
        // are pure recomputes from already-scanned data — switching the period never
        // triggers a git re-scan. The delta is now a SINGLE overall NET line — how much the
        // whole codebase grew (▲, blue) or shrank (▼, pink) over the period, a churn-free
        // cumulative-state difference (a line churned 5× counts once). The honest two-sided
        // added/removed churn display is gone (the user wanted "общая дельта", one number).
        let breakdown = dataProseBreakdown(stats)
        let net = netLinesDelta(history, period: period, now: .now)
        let triangle = deltaTriangle(net: net)
        // File-count delta isn't derivable from line history client-side, so the file
        // caption stays a plain count (the per-day series carries only lines).
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                CardLabel(title: "Totals", systemImage: "chart.pie.fill")
                Spacer(minLength: 8)
                periodControl
                // Opens the separate stats-settings page (the directory+file
                // exclusion tree); disabled until a project is selected.
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
            HStack(alignment: .top, spacing: 24) {
                // The headline is the LANGUAGE-GROUP split: total lines of non-data/prose
                // languages ("code") vs data/prose languages ("data"). Distinct axis from
                // the line-kind strip below, hence the "lines · N files" caption (it is
                // total lines of the code-language group, not the code-only line kind).
                headlineNumber(value: breakdown.codeLinesText,
                               caption: "code · \(breakdown.codeFilesText) files")
                headlineNumber(value: breakdown.dataProseLinesText,
                               caption: "data · \(breakdown.dataProseFilesText) files")
            }
            // ONE overall net delta for the whole project over the selected period: ▲ blue
            // when it grew, ▼ pink when it shrank, ±0 gray when flat. The period control
            // above drives this; the bars chart below has its own (decoupled) window.
            HStack(spacing: 6) {
                Text(triangle.label)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(triangleColor(triangle.direction))
                Text("net over \(period.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    /// One headline column: a big number and a caption. The period delta is no longer
    /// per-column (it was the misleading two-sided added/removed churn) — there is now a
    /// single overall net line shown once under both headlines in `totalsCard`.
    private func headlineNumber(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
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
        let bars = languageBars(stats)
        return VStack(alignment: .leading, spacing: 8) {
            CardLabel(title: "Languages", systemImage: "chevron.left.forwardslash.chevron.right")
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
                Divider().opacity(0.4)
                languageTable(bars)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard()
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
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color)
                        // A non-zero language always shows a sliver, like ProgressBar.
                        .frame(width: bar.fraction > 0
                               ? max(geo.size.width * bar.fraction, 4) : 0)
                }
            }
            .frame(height: 8)
            Text(bar.codeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    /// A small per-language table: language, files, code, comment, blank, %. The %
    /// is each language's `total` over the summed total across languages.
    private func languageTable(_ bars: [LanguageBar]) -> some View {
        let totalAll = max(bars.reduce(0) { $0 + $1.code + $1.comment + $1.blank }, 1)
        return VStack(spacing: 3) {
            HStack(spacing: 6) {
                tableCell("Language", .caption2.weight(.semibold), .secondary, leading: true)
                tableCell("Files", .caption2.weight(.semibold), .secondary)
                tableCell("Code", .caption2.weight(.semibold), .secondary)
                tableCell("Comment", .caption2.weight(.semibold), .secondary)
                tableCell("Blank", .caption2.weight(.semibold), .secondary)
                tableCell("%", .caption2.weight(.semibold), .secondary)
            }
            ForEach(bars) { bar in
                let share = Double(bar.code + bar.comment + bar.blank) / Double(totalAll) * 100
                // Data/prose languages read in a muted neutral so the group is visible at
                // a glance even in the dense table.
                let isData = CodeStatsEngine.isDataProse(bar.language)
                HStack(spacing: 6) {
                    tableCell(bar.language, .caption2,
                              isData ? Palette.neutral : .primary, leading: true)
                    tableCell(bar.filesText, .caption2)
                    tableCell(bar.codeText, .caption2)
                    tableCell(bar.commentText, .caption2)
                    tableCell(bar.blankText, .caption2)
                    tableCell("\(Int(share.rounded()))%", .caption2)
                }
            }
        }
    }

    private func tableCell(_ text: String, _ font: Font, _ color: Color = .primary,
                           leading: Bool = false) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: leading ? 110 : .infinity,
                   alignment: leading ? .leading : .trailing)
    }

    // MARK: - Per-repo blocks

    /// A compact block per git repo: name, its default branch (read-only chip for now),
    /// total LOC, and its delta over the SAME selected period as the Totals card. Single-
    /// repo projects collapse to one block; multi-repo (e.g. acme.shop's 4) stack
    /// tight inside one card.
    @ViewBuilder
    private func reposCard() -> some View {
        let repos = state.repoStats[selectedProjectID ?? UUID()] ?? []
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
    private func growthCard() -> some View {
        let repos = state.repoStats[selectedProjectID ?? UUID()] ?? []
        let bars = stackedRepoSeries(repos, daysBack: stackedBarMaxDaysBack, now: .now)
        let colors = repoColorMap(repos)
        let hasCode = bars.contains { $0.total > 0 }
        return VStack(alignment: .leading, spacing: 8) {
            CardLabel(title: "Lines over time", systemImage: "chart.bar.fill")
            stackedReadout(bars, repoCount: repos.count, colors: colors)
            if !hasCode {
                Text("No code history in this window yet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: growthChartHeight, alignment: .leading)
            } else {
                if isSnapshotRender {
                    // The manual stacked bars draw fine offscreen (Swift-Charts-free); the
                    // snapshot just trims to the most-recent visible window so the dense
                    // chart reads without a horizontal scroller.
                    stackedFallback(bars, colors: colors)
                } else {
                    stackedScroller(bars, colors: colors)
                }
                stackedLegend(repos, colors: colors)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard()
    }

    /// The readout above the chart: either the tapped day's total + per-repo breakdown
    /// tooltip, or a neutral hint of how many repos are stacked. Tinted blue (the codebase
    /// size axis). A day is selected by tapping a bar in the live strip.
    @ViewBuilder
    private func stackedReadout(_ bars: [StackedDayBar], repoCount: Int,
                                colors: [String: Color]) -> some View {
        if let day = selectedDay, let bar = bars.first(where: { $0.date == day }) {
            VStack(alignment: .leading, spacing: 1) {
                Text(stackedDayReadout(bar))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !bar.segments.isEmpty {
                    // Per-repo breakdown of that day, biggest-first (segment order).
                    Text(bar.segments
                        .map { "\($0.repoName) \(groupedThousands($0.lines))" }
                        .joined(separator: " · "))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        } else {
            Text("\(repoCount) \(repoCount == 1 ? "repo" : "repos") stacked · "
                 + (isSnapshotRender ? "codebase size over time" : "tap a bar for that day’s total"))
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
    private func stackedScroller(_ bars: [StackedDayBar], colors: [String: Color]) -> some View {
        let peak = stackedPeak(bars)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(bars) { bar in
                        stackedBarColumn(bar, peak: peak, colors: colors)
                            .frame(width: stackedSlotWidth)
                            .id(bar.date)
                            .contentShape(Rectangle())
                            .onTapGesture { toggleDaySelection(bar) }
                    }
                }
                .frame(height: growthChartHeight, alignment: .bottom)
            }
            .frame(height: growthChartHeight)
            .onAppear { if let last = bars.last { proxy.scrollTo(last.date, anchor: .trailing) } }
        }
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

    /// One segment's tint: the repo's stable color, full-strength when nothing is selected
    /// or this is the selected day, muted otherwise so the tapped bar stands out.
    private func segmentFill(_ seg: StackedSegment, on bar: StackedDayBar,
                             colors: [String: Color]) -> Color {
        let base = colors[seg.repoName] ?? Palette.primary
        guard selectedDay != nil else { return base }
        return selectedDay == bar.date ? base : base.opacity(0.45)
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
    private func stackedFallback(_ bars: [StackedDayBar], colors: [String: Color]) -> some View {
        GeometryReader { geo in
            stackedFallbackContent(bars, size: geo.size, colors: colors)
        }
        .frame(height: growthChartHeight)
    }

    /// The actual stacked rects for `stackedFallback`, against a resolved `size`. Trims to
    /// the most-recent `floor(width / slot)` days so the offscreen strip fills the card
    /// without a scroller, then draws each day as a bottom-up stack of per-repo segments
    /// (biggest at the bottom) proportional to that day's total. Pulled out of the
    /// GeometryReader closure so the geometry math doesn't fight the ViewBuilder.
    private func stackedFallbackContent(_ bars: [StackedDayBar], size: CGSize,
                                        colors: [String: Color]) -> some View {
        let w = size.width, h = size.height
        let slot = max(stackedSlotWidth, 1)
        let visibleCount = max(min(bars.count, Int(w / slot)), 1)
        let visible = Array(bars.suffix(visibleCount))
        let peak = stackedPeak(bars)
        let barWidth = max(slot - 1, 1)
        return ZStack(alignment: .bottomLeading) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { i, bar in
                let x = CGFloat(i) * slot
                // reversed(): smallest on top, biggest at the bottom.
                VStack(spacing: 0) {
                    ForEach(Array(bar.segments.enumerated().reversed()), id: \.offset) { _, seg in
                        Rectangle()
                            .fill(colors[seg.repoName] ?? Palette.primary)
                            .frame(width: barWidth,
                                   height: stackedSegmentHeight(lines: seg.lines, peak: peak, height: h))
                    }
                }
                .offset(x: x, y: 0)
                .frame(maxHeight: .infinity, alignment: .bottom)
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
