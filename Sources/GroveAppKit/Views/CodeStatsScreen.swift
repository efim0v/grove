import SwiftUI
import GroveCore

/// Code-stats tab (Stage 5): a per-project cloc-style breakdown rendered from the
/// pure presentation models in CodeStatsPresentation. Gray cards stacked in a
/// scroll: a totals header (big numbers), a language breakdown (horizontal bars +
/// a small per-language table), a per-day churn histogram (lines over time).
/// Folder/file exclusion now lives on a separate page (StatsSettingsScreen),
/// reached via the gear in the Totals header.
///
/// The scan is lazy: `.task(id:)` triggers `state.refreshCodeStats` whenever the
/// selected project changes, so opening the tab is what kicks off the (off-main)
/// walk — the global 15s refresh never pays for stats. The churn histogram is a
/// hand-drawn SwiftUI bar strip (no Swift Charts), but a `ScrollView`'s content is
/// still not laid out under ImageRenderer, so `isSnapshotRender` swaps in a manual
/// edge-to-edge bars fallback (same landmine the rest of the app handles).
struct CodeStatsScreen: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    /// The window the Totals card + per-repo blocks recompute their deltas over.
    /// Pure client-side recompute from the per-day history — never a re-scan.
    @State private var period: StatsPeriod = .d30

    /// The currently-tapped churn day in the "Lines over time" histogram, if any.
    /// Tapping a bar selects that calendar day → a "+added / −removed" tooltip above
    /// the chart; tapping it again (or an empty day) clears. Live-only (the snapshot
    /// path renders every bar without a selection).
    @State private var selectedChurnDay: Date?

    /// "Show empty days" toggle in the "Lines over time" header. OFF (default): the
    /// dense histogram fills every calendar day but zero-churn (no-commit) days are
    /// just empty space. ON: those days render as faint GRAY ticks so the gaps in
    /// activity are visible-but-muted (per the reference: "no transparent gaps; a
    /// toggle grays the empty days").
    @State private var showEmptyDays: Bool = false

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
            // A churn-day selection is scoped to one project's series; clear it so a
            // stale date from the previous project can't resolve against a same-calendar
            // day in the new one (bar dates are GMT start-of-day).
            selectedChurnDay = nil
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
        // Both headline numbers (Code / Data·Prose), the file counts, and the period
        // deltas are pure recomputes from already-scanned data — switching the period
        // never triggers a git re-scan. The deltas are now CLASSIFIED per language
        // group: each headline shows BOTH its honest gross additions (▲, blue) and
        // deletions (▼, pink) from the per-day code/data-split churn series, instead of
        // a single net triangle that hid the removed count.
        let breakdown = dataProseBreakdown(stats)
        let deltas = periodDeltasByCategory(history, period: period, now: .now)
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
                //
                // The period delta under each headline is now CLASSIFIED to match its
                // VALUE: the Code column shows the code-language churn (▲ added / ▼ removed)
                // and Data/Prose shows its OWN data/prose churn — no more static ±0, and no
                // more shared churn that inflated Code with JSON/Markdown commits. Both
                // sides are shown so the additions don't masquerade as net growth.
                headlineNumber(value: breakdown.codeLinesText,
                               caption: "code · \(breakdown.codeFilesText) files",
                               delta: deltas.code)
                headlineNumber(value: breakdown.dataProseLinesText,
                               caption: "data · \(breakdown.dataProseFilesText) files",
                               delta: deltas.dataProse)
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

    /// The 7d / 30d / 90d / All segmented control. Pure-SwiftUI (Buttons) so it renders
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

    /// One headline column: a big number, the period's HONEST two-sided churn (▲ added in
    /// blue AND ▼ removed in pink, side by side), and a caption. Showing both counts means
    /// the additions never masquerade as net growth — a refactor window reads as a large ▲
    /// next to an equally large ▼. When a side is zero it renders a muted "±0".
    private func headlineNumber(value: String, caption: String,
                                delta: CategoryDelta) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 8) {
                Text(delta.addedText)
                    .foregroundStyle(delta.added > 0 ? Palette.primary : Palette.neutral)
                Text(delta.removedText)
                    .foregroundStyle(delta.removed > 0 ? Palette.negative : Palette.neutral)
            }
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
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
            VStack(alignment: .leading, spacing: 8) {
                CardLabel(title: repos.count > 1 ? "Repositories" : "Repository",
                          systemImage: "shippingbox")
                VStack(spacing: 6) {
                    ForEach(cards) { card in
                        repoBlock(card)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .glassCard()
        }
    }

    private func repoBlock(_ card: RepoCard) -> some View {
        HStack(spacing: 8) {
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

    // MARK: - Churn histogram ("Lines over time")

    private let growthChartHeight: CGFloat = 120
    /// Each calendar-day bar's slot width (bar + 1px gap). 4pt at ~180 visible days
    /// fills a ~720pt plot — the dense reference look — while the ScrollView lets older
    /// days (back to the 1-year cap) scroll into view.
    private let churnSlotWidth: CGFloat = 4

    /// The "Lines over time" card, now a DENSE per-day CHURN histogram: one thin bar per
    /// calendar day in the window (no transparent gaps), each STACKED — a blue lower
    /// segment for lines ADDED that day and a pink upper segment for lines REMOVED — with
    /// the bar's height proportional to that day's TOTAL churn (added + removed). This is
    /// NON-cumulative codebase activity, not a running total: it shows where the work
    /// actually happened.
    ///
    /// The histogram's window is DECOUPLED from the Totals 7d/30d/90d/All period: the
    /// series always spans the full 1-year cap (`churnBarMaxDaysBack`) so the strip is
    /// genuinely scrollable, and it opens scrolled to today with ~`churnDefaultVisibleDays`
    /// (6 months) filling the viewport. The Totals/Repos `period` only drives the delta
    /// triangles, not this chart.
    private func growthCard() -> some View {
        let bars = churnBarSeries(history, daysBack: churnBarMaxDaysBack, now: .now)
        let activeDays = bars.filter { $0.totalChurn > 0 }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                CardLabel(title: "Lines over time", systemImage: "chart.bar.fill")
                Spacer(minLength: 8)
                emptyDaysToggle
            }
            churnReadout(bars, activeDays: activeDays)
            if activeDays == 0 {
                Text("No commit activity in this window yet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: growthChartHeight, alignment: .leading)
            } else if isSnapshotRender {
                // The manual stacked bars draw fine offscreen (Swift-Charts-free); the
                // snapshot just trims to the most-recent visible window so the dense
                // histogram reads without a horizontal scroller.
                churnFallback(bars)
            } else {
                churnScroller(bars)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard()
    }

    /// "Show empty days" checkbox in the card header. OFF: no-commit days are blank space.
    /// ON: they render as faint gray ticks so the gaps in activity are visible-but-muted.
    /// Pure-SwiftUI (a Button, not an AppKit Toggle) so it renders identically live and
    /// offscreen — like `periodControl`, AppKit checkboxes draw as error placeholders
    /// under ImageRenderer.
    private var emptyDaysToggle: some View {
        Button {
            showEmptyDays.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showEmptyDays ? "checkmark.square.fill" : "square")
                    .foregroundStyle(showEmptyDays ? Palette.primary : Color.secondary)
                Text("Empty days")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .help("Show no-commit days as faint gray ticks")
    }

    /// The readout above the histogram: either the tapped day's "+added / −removed"
    /// tooltip (tinted by which side dominates) or a neutral summary of the window's
    /// active days. A churn day means a calendar day with at least one commit.
    @ViewBuilder
    private func churnReadout(_ bars: [ChurnBarPoint], activeDays: Int) -> some View {
        if let day = selectedChurnDay, let bar = bars.first(where: { $0.date == day }) {
            Text(churnDayReadout(bar))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(bar.dayAdded >= bar.dayRemoved ? Palette.primary : Palette.negative)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            Text("\(groupedThousands(activeDays)) active \(activeDays == 1 ? "day" : "days") · "
                 + (isSnapshotRender ? "" : "tap a bar for that day’s churn"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// One churn bar's lower (added, blue) tint. The tapped day renders full-strength;
    /// every other bar slightly muted so the selection stands out (and at full strength
    /// when nothing is selected). Factored into one helper so reference-image tuning
    /// touches a single place.
    private func addedFill(_ bar: ChurnBarPoint) -> Color {
        guard selectedChurnDay != nil else { return Palette.primary }
        return selectedChurnDay == bar.date ? Palette.primary : Palette.primary.opacity(0.45)
    }

    /// One churn bar's upper (removed, pink) tint, mirroring `addedFill`.
    private func removedFill(_ bar: ChurnBarPoint) -> Color {
        guard selectedChurnDay != nil else { return Palette.negative }
        return selectedChurnDay == bar.date ? Palette.negative : Palette.negative.opacity(0.45)
    }

    /// The live histogram: a horizontally-scrollable strip of fixed-width per-day bars.
    /// A `ScrollView(.horizontal)` (rather than a width-fitted Swift Chart) keeps the bar
    /// density crisp and constant — the series spans the full 1-year cap, so ~180 days
    /// (`churnDefaultVisibleDays` × `churnSlotWidth` ≈ 720pt) fill the default viewport and
    /// the remaining ~185 older days scroll in. Starts scrolled to the most-recent day. A
    /// tap on any bar selects that day for the tooltip readout; tapping it clears it.
    private func churnScroller(_ bars: [ChurnBarPoint]) -> some View {
        let peak = churnPeak(bars)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(bars) { bar in
                        churnBarColumn(bar, peak: peak)
                            .frame(width: churnSlotWidth)
                            .id(bar.date)
                            .contentShape(Rectangle())
                            .onTapGesture { toggleChurnSelection(bar) }
                    }
                }
                .frame(height: growthChartHeight, alignment: .bottom)
            }
            .frame(height: growthChartHeight)
            .onAppear { if let last = bars.last { proxy.scrollTo(last.date, anchor: .trailing) } }
        }
    }

    /// One day's column in the live strip: the stacked bar (blue added over pink removed),
    /// or — for a zero-churn day — a faint gray baseline tick when "Empty days" is on, else
    /// nothing. Uses a GeometryReader so segment heights normalize against the plot box.
    private func churnBarColumn(_ bar: ChurnBarPoint, peak: Int) -> some View {
        GeometryReader { geo in
            let h = churnBarHeights(bar, peak: peak, height: geo.size.height)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if bar.totalChurn == 0 {
                    if showEmptyDays {
                        // A faint 1px baseline tick marks a no-commit day.
                        Rectangle()
                            .fill(Palette.neutral.opacity(0.3))
                            .frame(width: max(churnSlotWidth - 1, 1), height: 1)
                    }
                } else {
                    // Pink (removed) sits ABOVE blue (added) — a stacked churn bar.
                    Rectangle()
                        .fill(removedFill(bar))
                        .frame(width: max(churnSlotWidth - 1, 1), height: h.removed)
                    Rectangle()
                        .fill(addedFill(bar))
                        .frame(width: max(churnSlotWidth - 1, 1), height: h.added)
                }
            }
            .frame(maxWidth: .infinity, alignment: .bottom)
        }
    }

    /// Tap handling: select the tapped day (showing its tooltip), or clear if it was
    /// already selected. Zero-churn days clear any selection (nothing to show).
    private func toggleChurnSelection(_ bar: ChurnBarPoint) {
        if selectedChurnDay == bar.date || bar.totalChurn == 0 {
            selectedChurnDay = nil
        } else {
            selectedChurnDay = bar.date
        }
    }

    /// Snapshot fallback: a manual stacked-bar render (Swift Charts draw blank under
    /// ImageRenderer, and a ScrollView's content isn't laid out offscreen either, so the
    /// snapshot trims to the most-recent days that fit the card and draws them edge-to-
    /// edge). Selection is live-only, so every bar draws at full strength.
    private func churnFallback(_ bars: [ChurnBarPoint]) -> some View {
        GeometryReader { geo in
            churnFallbackContent(bars, size: geo.size)
        }
        .frame(height: growthChartHeight)
    }

    /// The actual stacked rects for `churnFallback`, against a resolved `size`. Trims to
    /// the most-recent `floor(width / slot)` days so the offscreen strip fills the card
    /// without a scroller, then draws each as a blue(added)-over-pink(removed) stack
    /// proportional to its total churn. Pulled out of the GeometryReader closure so the
    /// geometry math doesn't fight the ViewBuilder.
    private func churnFallbackContent(_ bars: [ChurnBarPoint], size: CGSize) -> some View {
        let w = size.width, h = size.height
        let slot = max(churnSlotWidth, 1)
        let visibleCount = max(min(bars.count, Int(w / slot)), 1)
        let visible = Array(bars.suffix(visibleCount))
        let peak = churnPeak(bars)
        let barWidth = max(slot - 1, 1)
        return ZStack(alignment: .bottomLeading) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { i, bar in
                let heights = churnBarHeights(bar, peak: peak, height: h)
                let x = CGFloat(i) * slot
                if bar.totalChurn == 0 {
                    if showEmptyDays {
                        Rectangle()
                            .fill(Palette.neutral.opacity(0.3))
                            .frame(width: barWidth, height: 1)
                            .offset(x: x, y: 0)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                } else {
                    // Bottom blue (added) + pink (removed) stacked above it.
                    VStack(spacing: 0) {
                        Rectangle().fill(Palette.negative).frame(width: barWidth, height: heights.removed)
                        Rectangle().fill(Palette.primary).frame(width: barWidth, height: heights.added)
                    }
                    .offset(x: x, y: 0)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
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
