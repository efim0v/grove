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
            // The skeleton is cheap (walks dirs, reads no files); load it off-main
            // before the heavier scan so the exclusion tree is ready when stats land.
            dirTree = await state.statsDirectoryTree(projectID: id)
            await state.refreshCodeStats(projectID: id)
        }
    }

    private var selectedProjectID: UUID? { state.selectedProjectID }

    // MARK: - Populated content

    @ViewBuilder
    private func content(stats: CodeStats) -> some View {
        let cards = VStack(spacing: 8) {
            totalsCard(stats: stats)
            languageCard(stats: stats)
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
        let totals = statsTotals(stats)
        return VStack(alignment: .leading, spacing: 8) {
            CardLabel(title: "Totals", systemImage: "chart.pie.fill")
            HStack(spacing: 20) {
                bigNumber(groupedThousands(totals.totalLines), "lines")
                bigNumber(groupedThousands(totals.totalFiles), "files")
                bigNumber("\(totals.codePercent)%", "code")
            }
            HStack(spacing: 12) {
                metric("Code", stats.code, .green)
                metric("Comment", stats.comment, .cyan)
                metric("Blank", stats.blank, .secondary)
                if state.isStatsScanning {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard()
    }

    private func bigNumber(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
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
                ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                    languageBarRow(bar, color: laneColor(index))
                }
                Divider().opacity(0.4)
                languageTable(bars)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard()
    }

    /// Color from GraphScreen.lanePalette, cycled — keeps the stats hues consistent
    /// with the graph's lane colors.
    private func laneColor(_ index: Int) -> Color {
        GraphScreen.lanePalette[index % GraphScreen.lanePalette.count]
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
                HStack(spacing: 6) {
                    tableCell(bar.language, .caption2, .primary, leading: true)
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

    // MARK: - Growth chart (lines over time)

    private func growthCard() -> some View {
        let series = growthSeries(state.codeStatsHistory[selectedProjectID ?? UUID()] ?? [])
        return VStack(alignment: .leading, spacing: 8) {
            CardLabel(title: "Lines over time", systemImage: "chart.xyaxis.line")
            if series.count < 2 {
                Text("Not enough history yet — the curve appears after a few scans.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            } else if isSnapshotRender {
                growthFallback(series)
            } else {
                growthChart(series)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard()
    }

    private func growthChart(_ series: [GrowthPoint]) -> some View {
        Chart(series) { point in
            LineMark(x: .value("Date", point.date),
                     y: .value("Lines", point.totalLines))
                .foregroundStyle(cardAccent)
                .interpolationMethod(.monotone)
            AreaMark(x: .value("Date", point.date),
                     y: .value("Lines", point.totalLines))
                .foregroundStyle(cardAccent.opacity(0.12))
                .interpolationMethod(.monotone)
        }
        .chartYAxis { AxisMarks { AxisValueLabel().font(.caption2) } }
        .chartXAxis { AxisMarks { AxisValueLabel().font(.caption2) } }
        .frame(height: 120)
    }

    /// Manual line for snapshot mode (Swift Charts render blank offscreen). A simple
    /// Path over the series' lines, normalized to the plot box.
    private func growthFallback(_ series: [GrowthPoint]) -> some View {
        GeometryReader { geo in
            growthFallbackContent(series, size: geo.size)
        }
        .frame(height: 120)
    }

    /// The actual area-fill + line paths for `growthFallback`, computed against a
    /// resolved `size`. Pulled out of the GeometryReader closure so the geometry
    /// math (local lets + a point helper) doesn't fight the ViewBuilder.
    private func growthFallbackContent(_ series: [GrowthPoint], size: CGSize) -> some View {
        let values = series.map(\.totalLines)
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 1
        let span = CGFloat(max(maxV - minV, 1))
        let w = size.width, h = size.height
        let step = series.count > 1 ? w / CGFloat(series.count - 1) : 0
        func point(_ i: Int) -> CGPoint {
            let frac = CGFloat(values[i] - minV) / span
            return CGPoint(x: CGFloat(i) * step, y: h - frac * h)
        }
        return ZStack {
            // Filled area under the line.
            Path { p in
                p.move(to: CGPoint(x: 0, y: h))
                for i in series.indices { p.addLine(to: point(i)) }
                p.addLine(to: CGPoint(x: CGFloat(series.count - 1) * step, y: h))
                p.closeSubpath()
            }
            .fill(cardAccent.opacity(0.12))
            // The line itself.
            Path { p in
                p.move(to: point(0))
                for i in series.indices.dropFirst() { p.addLine(to: point(i)) }
            }
            .stroke(cardAccent, lineWidth: 2)
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
