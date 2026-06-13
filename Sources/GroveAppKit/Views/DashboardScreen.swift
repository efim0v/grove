import SwiftUI
import Charts
import GroveCore

/// The Charts tab (item 4): the usage dashboard from the reference, rendered with
/// native Swift Charts. Shows an "Overall" column plus one column per account,
/// laid out side by side (horizontally scrollable when there are many accounts).
struct DashboardScreen: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    /// Column width tuned to the reference (~one phone-width card stack).
    static let columnWidth: CGFloat = 290

    private func columns() -> [DashboardColumn] {
        let now = Date()
        let overall = overallDashboard(
            analyticsByAccount: state.usageByAccount,
            snapshotsByAccount: state.snapshotsByAccount,
            aggregateFiveHour: state.aggregateRemaining(window: .fiveHour, now: now),
            aggregateWeekly: state.aggregateRemaining(window: .sevenDay, now: now),
            now: now)
        let perAccount = state.config.accounts.map { account in
            accountDashboard(name: account.name,
                             analytics: state.usageByAccount[account.name],
                             snapshots: state.snapshotsByAccount[account.name] ?? [],
                             now: now)
        }
        // Overall is only meaningful alongside ≥2 accounts; with one account it
        // duplicates that account, so collapse to a single column.
        return perAccount.count <= 1 ? (perAccount.isEmpty ? [overall] : perAccount)
                                     : [overall] + perAccount
    }

    var body: some View {
        let cols = columns()
        let stack = HStack(alignment: .top, spacing: 12) {
            ForEach(cols) { column in
                DashboardColumnView(column: column, isSnapshotRender: isSnapshotRender)
                    .frame(width: Self.columnWidth)
            }
        }
        .padding(12)
        // ImageRenderer doesn't lay out ScrollView content offscreen, so the
        // snapshot draws the columns in a plain stack; the live panel scrolls
        // both ways (tall columns, many account columns).
        return Group {
            if isSnapshotRender {
                stack.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView([.horizontal, .vertical], showsIndicators: true) { stack }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One scope's vertical card stack (Overall or one account).
struct DashboardColumnView: View {
    let column: DashboardColumn
    let isSnapshotRender: Bool

    var body: some View {
        VStack(spacing: 10) {
            Text(column.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            LimitCardView(card: column.fiveHour)
            LimitCardView(card: column.weekly)
            UsageRateCardView(points: column.usageRate, isSnapshotRender: isSnapshotRender)
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
                Text(card.resetCaption.isEmpty ? "Resets in: —" : "Resets in: \(card.resetCaption)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(card.note)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(noteColor)
            }
        }
        .padding(12)
        .glassCard()
    }

    private var noteColor: Color {
        if card.noteIsWarning { return .orange }
        return card.note == "On track" ? .green : .secondary
    }
}

// MARK: - Usage-rate line chart

struct UsageRateCardView: View {
    let points: [UsageRatePoint]
    let isSnapshotRender: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Usage Rate", systemImage: "chart.xyaxis.line")
                .font(.callout.weight(.semibold))
            if points.count < 2 {
                placeholder("Not enough captures yet")
            } else if isSnapshotRender {
                // ImageRenderer can draw Swift Charts blank offscreen; a plain
                // sparkline keeps the snapshot legible.
                Sparkline(values: points.map(\.percent))
                    .stroke(.green, lineWidth: 1.5)
                    .frame(height: 80)
            } else {
                Chart(points) { p in
                    AreaMark(x: .value("Time", p.time),
                             y: .value("Used %", p.percent))
                        .foregroundStyle(.green.opacity(0.18))
                    LineMark(x: .value("Time", p.time),
                             y: .value("Used %", p.percent))
                        .foregroundStyle(.green)
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                .chartXAxis(.hidden)
                .frame(height: 80)
            }
        }
        .padding(12)
        .glassCard()
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}

/// Minimal sparkline path used as the snapshot-mode fallback for the line chart.
struct Sparkline: Shape {
    let values: [Double]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let maxV = max(values.max() ?? 1, 1)
        let stepX = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let x = rect.minX + CGFloat(i) * stepX
            let y = rect.maxY - CGFloat(v / maxV) * rect.height
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

// MARK: - Daily usage bar chart

struct DailyUsageCardView: View {
    let bars: [DailyUsageBar]
    let isSnapshotRender: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Daily Usage", systemImage: "chart.bar.fill")
                .font(.callout.weight(.semibold))
            if bars.allSatisfy({ $0.totalTokens == 0 }) {
                Text("No usage in the last 7 days")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else if isSnapshotRender {
                snapshotBars
            } else {
                Chart(bars) { bar in
                    BarMark(x: .value("Day", bar.label),
                            y: .value("Tokens", bar.totalTokens),
                            width: .ratio(0.6))
                        .foregroundStyle(intensityColor(bar.intensity))
                        .cornerRadius(4)
                }
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks { AxisValueLabel().font(.caption2) } }
                .frame(height: 96)
            }
        }
        .padding(12)
        .glassCard()
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
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    header("Input"); header("Output"); header("Cache"); header("Cost")
                }
                ForEach(rows) { row in
                    GridRow {
                        Text(row.period).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        Text(formatCompactTokens(row.input)).monospacedDigit()
                        Text(formatCompactTokens(row.output)).monospacedDigit()
                        Text(formatCompactTokens(row.cache)).monospacedDigit()
                        Text(formatCompactCost(row.cost)).monospacedDigit()
                    }
                    .font(.caption)
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

    private func header(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }
}

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

// MARK: - Shared colour helpers

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
