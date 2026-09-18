import SwiftUI
import GroveCore

/// Shared multi-line session CARD used by both the Claude tab (`SessionsScreen`)
/// and the Other-Sessions screen. Renders a status+age line (with a caller-supplied
/// trailing `actions` slot), the FULL title (never truncated), a location·branch
/// line, and a meta line (account · created · duration · turns · model) — enough
/// context to decide what to resume without opening it. The row's tap gesture /
/// context menu are applied by the caller, not here.
struct SessionCard<Actions: View>: View {
    let row: SessionRow
    let now: Date
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusLine
                Spacer(minLength: 8)
                actions()
            }
            Text(row.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)   // wrap fully, never truncate
            locationLine
            metaLine
        }
        .padding(.vertical, 9)
    }

    // MARK: - Lines

    /// Status dot + word + age. Live rows show the process runtime ("busy · 4m
    /// running"); resumable rows show time since last activity ("resumable · 2d").
    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor(row.liveStatus)).frame(width: 7, height: 7)
            if let status = row.liveStatus {
                Text(statusWord(status)).foregroundStyle(.primary)
                if let startedAt = row.startedAt {
                    Text("· \(relativeAge(startedAt, now: now)) running").foregroundStyle(.secondary)
                }
            } else {
                Text("resumable").foregroundStyle(.secondary)
                Text("· \(relativeAge(row.lastActivity, now: now))").foregroundStyle(.tertiary)
            }
        }
        .font(.caption.weight(.medium))
    }

    /// Location + git branch, full width (no fixed column → a long workspace/branch
    /// name no longer reads as "kp-bus…landing").
    private var locationLine: some View {
        HStack(spacing: 5) {
            Image(systemName: "shippingbox").foregroundStyle(.tertiary)
            Text(row.location).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let branch = row.gitBranch, !branch.isEmpty {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.tertiary)
                Text(branch).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.caption)
    }

    /// account · created Nd ago · ran <dur> · N turns · <model>. Only existing
    /// pieces are shown; wraps rather than truncates.
    private var metaLine: some View {
        var parts: [String] = [row.accountName]
        if let created = row.createdAt {
            parts.append("created \(relativeAge(created, now: now)) ago")
            let end = row.liveStatus != nil ? now : row.lastActivity
            let dur = durationString(from: created, to: end)
            if !dur.isEmpty { parts.append("ran \(dur)") }
        }
        if row.turnCount > 0 {
            parts.append("\(row.turnCount) turn\(row.turnCount == 1 ? "" : "s")")
        }
        if let model = row.model, !model.isEmpty { parts.append(shortModelName(model)) }
        return Text(parts.joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Helpers

    /// Compact elapsed-time for a duration (not "ago"): 45m / 3h / 5d / 2w. Empty
    /// for a sub-minute span so the meta line drops the "ran" clause.
    private func durationString(from start: Date, to end: Date) -> String {
        let seconds = max(0, end.timeIntervalSince(start))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        return "\(days / 7)w"
    }

    private func dotColor(_ status: SessionLiveStatus?) -> Color {
        switch status {
        case .busy: return Palette.primary
        case .waiting: return Palette.mid
        case .idle: return Palette.neutral
        case nil: return Palette.neutral
        }
    }

    private func statusWord(_ status: SessionLiveStatus) -> String {
        switch status {
        case .busy: return "busy"
        case .waiting: return "waiting"
        case .idle: return "idle"
        }
    }
}
