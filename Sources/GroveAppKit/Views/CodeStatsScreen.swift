import SwiftUI
import Charts
import GroveCore

/// Code-stats tab (Stage 5): a per-project cloc-style breakdown rendered from the
/// pure presentation models in CodeStatsPresentation. Four gray cards stacked in a
/// scroll: a totals header (big numbers), a language breakdown (horizontal bars +
/// a small per-language table), a growth chart (lines over time), and a toggleable
/// folder-exclusion tree.
///
/// The scan is lazy: `.task(id:)` triggers `state.refreshCodeStats` whenever the
/// selected project changes, so opening the tab is what kicks off the (off-main)
/// walk — the global 15s refresh never pays for stats. Like GraphScreen/
/// DashboardScreen, the Swift Charts growth chart renders BLANK under
/// ImageRenderer, so `isSnapshotRender` swaps in a manual Path/bars fallback.
struct CodeStatsScreen: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    /// The directory skeleton for the exclusion tree, loaded lazily alongside the
    /// scan. Held locally (not on AppState) because only this screen needs it; nil
    /// until the first load lands.
    @State private var dirTree: DirNode?

    /// The window the Totals card + per-repo blocks recompute their deltas over.
    /// Pure client-side recompute from the per-day history — never a re-scan.
    @State private var period: StatsPeriod = .d30

    /// Up to two selected bar dates in the growth chart: tapping a bar appends; a
    /// THIRD tap resets. Two selected → a "+X added · −Y removed · net Z" readout.
    /// Live-only (snapshot mode renders bars without selection).
    @State private var selectedBars: [Date] = []

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
            // A growth-bar selection is scoped to one project's series; clear it so a
            // stale date from the previous project can't resolve against a same-calendar
            // day in the new one (bar dates are GMT start-of-day).
            selectedBars = []
            // The skeleton is cheap (walks dirs, reads no files); load it off-main
            // before the heavier scan so the exclusion tree is ready when stats land.
            dirTree = await state.statsDirectoryTree(projectID: id)
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
            treeCard()
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
        // delta are pure recomputes from already-scanned data — switching the period
        // never triggers a git re-scan.
        let breakdown = dataProseBreakdown(stats)
        let delta = periodDelta(history, period: period, now: .now)
        let codeTriangle = deltaTriangle(net: delta.net)
        // File-count delta isn't derivable from line history client-side, so the file
        // caption stays a plain count (the per-day series carries only lines).
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                CardLabel(title: "Totals", systemImage: "chart.pie.fill")
                Spacer(minLength: 8)
                periodControl
            }
            HStack(alignment: .top, spacing: 24) {
                // The headline is the LANGUAGE-GROUP split: total lines of non-data/prose
                // languages ("code") vs data/prose languages ("data"). Distinct axis from
                // the line-kind strip below, hence the "lines · N files" caption (it is
                // total lines of the code-language group, not the code-only line kind).
                //
                // NOTE: the period triangle here rides numstat churn, which is NOT
                // language-split (GitStatsService.bucketHistory sums added/removed over
                // ALL changed files). So a window heavy in JSON/Markdown commits inflates
                // this triangle even though those lines are excluded from the headline
                // VALUE. Accepted trade-off — a true per-language delta would need numstat
                // path classification in GitStatsService.parseLog. Data/Prose mirrors this:
                // it shows a flat ±0 marker since the single churn delta rides the code
                // headline.
                headlineNumber(value: breakdown.codeLinesText,
                               caption: "code · \(breakdown.codeFilesText) files",
                               triangle: codeTriangle)
                headlineNumber(value: breakdown.dataProseLinesText,
                               caption: "data · \(breakdown.dataProseFilesText) files",
                               triangle: DeltaTriangle(direction: .flat, label: "±0"))
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

    /// One headline column: a big number, a small ▲/▼ delta over the selected period,
    /// and a caption. The triangle is tinted by direction (up→primary, down→negative,
    /// flat→neutral).
    private func headlineNumber(value: String, caption: String,
                                triangle: DeltaTriangle) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(triangle.label)
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(triangleColor(triangle.direction))
                .lineLimit(1)
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
            // Read-only branch chip — the switcher is a later pass.
            Text(card.defaultBranch)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.white.opacity(0.08), in: Capsule())
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

    // MARK: - Growth chart (per-day bars)

    private let growthChartHeight: CGFloat = 120

    private func growthCard() -> some View {
        let bars = barSeries(history)
        return VStack(alignment: .leading, spacing: 8) {
            CardLabel(title: "Lines over time", systemImage: "chart.bar.fill")
            growthReadout(bars)
            if bars.count < 2 {
                Text("Not enough history yet — the bars appear after a few scans.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: growthChartHeight, alignment: .leading)
            } else if isSnapshotRender {
                // Swift Charts render blank under ImageRenderer — manual bars instead.
                // Selection is live-only, so the snapshot just draws every bar.
                barFallback(bars)
            } else {
                barChart(bars)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard()
    }

    /// The selection readout above the chart. Two bars selected → the window delta
    /// ("+X added · −Y removed · net Z", tinted by net sign); otherwise a hint.
    @ViewBuilder
    private func growthReadout(_ bars: [BarPoint]) -> some View {
        if let pair = selectedPair(in: bars) {
            let d = barSelectionDelta(from: pair.0, to: pair.1, in: bars)
            Text(barSelectionReadout(d))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(triangleColor(deltaTriangle(net: d.net).direction))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else if !isSnapshotRender && bars.count >= 2 {
            Text(selectedBars.isEmpty
                 ? "Select two bars to compare."
                 : "Select a second bar to compare.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Resolve the two currently-selected dates back to their `BarPoint`s, if exactly
    /// two are selected and both are still in the series.
    private func selectedPair(in bars: [BarPoint]) -> (BarPoint, BarPoint)? {
        guard selectedBars.count == 2,
              let a = bars.first(where: { $0.date == selectedBars[0] }),
              let b = bars.first(where: { $0.date == selectedBars[1] }) else { return nil }
        return (a, b)
    }

    /// One bar's fill. Factored into ONE helper (per spec) so later reference-image
    /// tuning touches a single place. Selected days render full-strength; everything
    /// else (or every bar when nothing is selected) at 0.85.
    private func barFill(_ bar: BarPoint) -> Color {
        selectedBars.contains(bar.date)
            ? Palette.primary
            : Palette.primary.opacity(selectedBars.isEmpty ? 0.85 : 0.4)
    }

    /// The live Swift Charts per-day bar chart. A tap maps the x-position to the nearest
    /// day and appends it to `selectedBars` (capped at two; a THIRD tap resets).
    private func barChart(_ bars: [BarPoint]) -> some View {
        Chart(bars) { bar in
            BarMark(x: .value("Date", bar.date, unit: .day),
                    y: .value("Lines", bar.cumulativeLines))
                .foregroundStyle(barFill(bar))
        }
        .chartYAxis { AxisMarks { AxisValueLabel().font(.caption2) } }
        .chartXAxis { AxisMarks { AxisValueLabel().font(.caption2) } }
        .frame(height: growthChartHeight)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let x = location.x - geo[plotFrame].origin.x
                        guard let date: Date = proxy.value(atX: x) else { return }
                        selectNearestBar(to: date, in: bars)
                    }
            }
        }
    }

    /// Append the bar nearest `date` to the selection (cap 2; third tap resets).
    private func selectNearestBar(to date: Date, in bars: [BarPoint]) {
        guard let nearest = bars.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }) else { return }
        if selectedBars.count >= 2 {
            selectedBars = [nearest.date]
        } else if !selectedBars.contains(nearest.date) {
            selectedBars.append(nearest.date)
        }
    }

    /// Manual bars for snapshot mode (Swift Charts render blank offscreen). One rect per
    /// day, heights normalized to the plot box. Mirrors the old growthFallback pattern.
    private func barFallback(_ bars: [BarPoint]) -> some View {
        GeometryReader { geo in
            barFallbackContent(bars, size: geo.size)
        }
        .frame(height: growthChartHeight)
    }

    /// The actual rects for `barFallback`, computed against a resolved `size`. Pulled out
    /// of the GeometryReader closure so the geometry math doesn't fight the ViewBuilder.
    private func barFallbackContent(_ bars: [BarPoint], size: CGSize) -> some View {
        let values = bars.map(\.cumulativeLines)
        let maxV = CGFloat(max(values.max() ?? 1, 1))
        let w = size.width, h = size.height
        let slot = bars.count > 0 ? w / CGFloat(bars.count) : w
        // Leave a hairline gap between bars at a clean default density.
        let barWidth = max(slot * 0.8, 1)
        return ZStack(alignment: .bottomLeading) {
            ForEach(Array(bars.enumerated()), id: \.element.id) { i, bar in
                let frac = CGFloat(bar.cumulativeLines) / maxV
                let barHeight = max(frac * h, 1)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(barFill(bar))
                    .frame(width: barWidth, height: barHeight)
                    .offset(x: CGFloat(i) * slot + (slot - barWidth) / 2,
                            y: 0)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    // MARK: - Exclusion tree

    private func treeCard() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CardLabel(title: "Folders", systemImage: "folder")
            Text("Toggle a folder off to exclude it from the scan.")
                .font(.caption2).foregroundStyle(.secondary)
            if let tree = dirTree {
                let rows = buildStatsTree(tree, ignoredFolders: ignoredFolders)
                if rows.isEmpty {
                    Text("No sub-folders to exclude.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        statsTreeRow(row)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading folders…").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard()
    }

    private var ignoredFolders: Set<String> {
        Set(state.selectedProject?.statsIgnoredFolders ?? [])
    }

    /// One folder row: a checkbox-style Toggle (INCLUDED = on) per folder. A folder
    /// excluded by an ancestor is shown on but disabled (the ancestor governs it).
    private func statsTreeRow(_ row: StatsTreeRow) -> some View {
        let included = Binding<Bool>(
            get: { !row.isExcluded },
            set: { include in
                guard let id = selectedProjectID else { return }
                state.setStatsFolderExcluded(projectID: id, relativePath: row.relativePath,
                                             excluded: !include)
            })
        return HStack(spacing: 6) {
            Toggle(isOn: included) {
                Text(row.name)
                    .font(.caption)
                    .foregroundStyle(row.isExcluded ? Color.secondary : Color.primary)
                    .lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .disabled(row.excludedByAncestor)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 14)
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
