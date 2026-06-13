import SwiftUI
import Charts
import GroveCore

/// The Charts tab: the usage dashboard from the reference, rendered with native
/// Swift Charts. ONE scope at a time (Overall, or a single account) chosen with
/// ‹ › arrows; the same widgets, different contents. No scroll — the panel is
/// sized to fit the whole column.
struct DashboardScreen: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    static let columnWidth: CGFloat = 320

    /// Every scope: "Overall" first when there is more than one account (otherwise
    /// it would just duplicate the sole account), then one per account.
    private func scopes() -> [DashboardColumn] {
        let now = Date()
        let perAccount = state.config.accounts.map { account in
            accountDashboard(name: account.name,
                             analytics: state.usageByAccount[account.name],
                             snapshots: state.snapshotsByAccount[account.name] ?? [],
                             now: now)
        }
        guard perAccount.count > 1 else { return perAccount }
        let overall = overallDashboard(
            analyticsByAccount: state.usageByAccount,
            snapshotsByAccount: state.snapshotsByAccount,
            aggregateFiveHour: state.aggregateRemaining(window: .fiveHour, now: now),
            aggregateWeekly: state.aggregateRemaining(window: .sevenDay, now: now),
            now: now)
        return [overall] + perAccount
    }

    var body: some View {
        let cols = scopes()
        if cols.isEmpty {
            emptyState
        } else {
            let index = min(max(state.chartsScopeIndex, 0), cols.count - 1)
            // Sizes to the cards' natural height (no scroll); the panel grows to fit.
            VStack(spacing: 10) {
                switcher(scopes: cols, index: index)
                DashboardColumnView(column: cols[index], isSnapshotRender: isSnapshotRender)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Scope switcher (‹ Title i/n ›)

    private func switcher(scopes cols: [DashboardColumn], index: Int) -> some View {
        HStack(spacing: 8) {
            arrow("chevron.left", enabled: index > 0) {
                state.chartsScopeIndex = max(0, index - 1)
            }
            VStack(spacing: 1) {
                Text(cols[index].title)
                    .font(.headline)
                    .lineLimit(1)
                if cols.count > 1 {
                    Text("\(index + 1) / \(cols.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity)
            arrow("chevron.right", enabled: index < cols.count - 1) {
                state.chartsScopeIndex = min(cols.count - 1, index + 1)
            }
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.35))
        .disabled(!enabled)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.secondary)
            Text("No accounts").font(.headline)
            Text("Add a Claude account to see its usage.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

/// One scope's stacked cards (the title lives in the switcher above).
struct DashboardColumnView: View {
    let column: DashboardColumn
    let isSnapshotRender: Bool

    var body: some View {
        VStack(spacing: 10) {
            LimitCardView(card: column.fiveHour)
            LimitCardView(card: column.weekly)
            DailyUsageCardView(bars: column.daily, isSnapshotRender: isSnapshotRender)
            TokenUsageCardView(rows: column.tokens, models: column.models)
        }
    }
}

// MARK: - Limit bar card (5-Hour Session / Weekly Limit)

struct LimitCardView: View {
    let card: LimitCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(card.title, systemImage: card.systemImage)
                    .font(.callout.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                Spacer()
                Text("\(Int(card.usedPercentage.rounded()))%")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(levelColor(card.level))
                    .monospacedDigit()
            }
            ProgressBar(fraction: card.usedPercentage / 100, color: levelColor(card.level))
                .frame(height: 9)
            HStack(spacing: 6) {
                Text(resetText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(card.note)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(noteColor)
                    .fixedSize()
            }
        }
        .padding(12)
        .glassCard()
    }

    private var resetText: String {
        guard !card.resetCaption.isEmpty else { return "Resets in: —" }
        let absolute = card.resetAbsolute.isEmpty ? "" : " \(card.resetAbsolute)"
        return "Resets in: \(card.resetCaption)\(absolute)"
    }

    private var noteColor: Color {
        if card.noteIsWarning { return .orange }
        return card.note == "On track" ? .green : .secondary
    }
}

// MARK: - Daily usage bar chart

struct DailyUsageCardView: View {
    let bars: [DailyUsageBar]
    let isSnapshotRender: Bool
    @State private var hoverLabel: String?

    var body: some View {
        let hovered = bars.first { $0.label == hoverLabel }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Daily Usage", systemImage: "chart.bar.fill")
                    .font(.callout.weight(.semibold))
                Spacer()
                // Unit when idle; the hovered bar's detail when pointing at one.
                if let hovered {
                    Text("\(hovered.label) · \(formatCompactTokens(hovered.totalTokens)) tok · \(formatCompactCost(hovered.cost))")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("tokens / day").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if bars.allSatisfy({ $0.totalTokens == 0 }) {
                Text("No usage in the last 7 days")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 96)
            } else if isSnapshotRender {
                snapshotBars
            } else {
                chart
            }
        }
        .padding(12)
        .glassCard()
    }

    private var chart: some View {
        Chart(bars) { bar in
            BarMark(x: .value("Day", bar.label),
                    y: .value("Tokens", bar.totalTokens),
                    width: .ratio(0.6))
                .foregroundStyle(intensityColor(bar.intensity)
                    .opacity(hoverLabel == nil || hoverLabel == bar.label ? 1 : 0.4))
                .cornerRadius(4)
        }
        .chartYAxis(.hidden)
        .chartXAxis { AxisMarks { AxisValueLabel().font(.caption2) } }
        .frame(height: 96)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let x = point.x - geo[proxy.plotAreaFrame].origin.x
                            hoverLabel = proxy.value(atX: x, as: String.self)
                        case .ended:
                            hoverLabel = nil
                        }
                    }
            }
        }
    }

    /// Manual bars for snapshot mode (Swift Charts can render blank offscreen).
    private var snapshotBars: some View {
        let maxTokens = max(bars.map(\.totalTokens).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(bars) { bar in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(intensityColor(bar.intensity))
                        .frame(height: max(2, CGFloat(bar.totalTokens) / CGFloat(maxTokens) * 70))
                    Text(bar.label).font(.system(size: 8)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .bottom)
            }
        }
        .frame(height: 96, alignment: .bottom)
    }
}

// MARK: - Token usage table + model breakdown

struct TokenUsageCardView: View {
    let rows: [TokenRow]
    let models: [ModelShare]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Token Usage", systemImage: "number")
                .font(.callout.weight(.semibold))
            // Columns spread evenly across the full card width (each maxWidth:∞).
            HStack(spacing: 8) {
                cell("", .caption2.weight(.semibold), .secondary, leading: true)
                cell("Input", .caption2.weight(.semibold), .secondary)
                cell("Output", .caption2.weight(.semibold), .secondary)
                cell("Cache", .caption2.weight(.semibold), .secondary)
                cell("Cost", .caption2.weight(.semibold), .secondary)
            }
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    cell(row.period, .caption, .secondary, leading: true)
                    cell(formatCompactTokens(row.input), .caption)
                    cell(formatCompactTokens(row.output), .caption)
                    cell(formatCompactTokens(row.cache), .caption)
                    cell(formatCompactCost(row.cost), .caption)
                }
            }
            if !models.isEmpty {
                Divider().opacity(0.4)
                ForEach(models) { share in
                    HStack {
                        Text(share.model).font(.caption).lineLimit(1)
                        Spacer()
                        Text("\(Int(share.percent.rounded()))%")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(12)
        .glassCard()
    }

    private func cell(_ text: String, _ font: Font, _ color: Color = .primary,
                      leading: Bool = false) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
    }
}

// MARK: - Shared chrome

/// A thick rounded capacity bar (the reference's limit bar). The fill width
/// tracks `fraction` (clamped to 0…1); a non-zero fraction always shows a sliver.
struct ProgressBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                let clamped = min(max(fraction, 0), 1)
                Capsule()
                    .fill(color)
                    .frame(width: clamped > 0 ? max(geo.size.width * clamped, 6) : 0)
            }
        }
    }
}

func levelColor(_ level: CapacityLevel) -> Color {
    switch level {
    case .noData: return .secondary
    case .plenty: return .green
    case .tight: return .orange
    case .critical: return .red
    }
}

/// Daily-bar colour by intensity (reference: orange busiest, yellow mid, green light).
func intensityColor(_ intensity: Double) -> Color {
    switch intensity {
    case 0.66...: return .orange
    case 0.33...: return .yellow
    default: return .green
    }
}
