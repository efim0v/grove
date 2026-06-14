import Foundation
import GroveCore

// Pure presentation logic for the usage dashboard (item 4 / reference). No
// SwiftUI, no I/O — every model below is built from already-loaded analytics +
// capture snapshots and is fully unit-testable. DashboardScreen renders these.

// MARK: - Compact number / cost formatting (reference: "3.9M", "5.9B", "$3.4k")

/// Compact token count: 1_234 -> "1.2k", 3_900_000 -> "3.9M", 5_900_000_000 -> "5.9B".
public func formatCompactTokens(_ n: Int) -> String {
    let value = Double(n)
    switch abs(value) {
    case 1_000_000_000...: return trim(value / 1_000_000_000) + "B"
    case 1_000_000...:     return trim(value / 1_000_000) + "M"
    case 1_000...:         return trim(value / 1_000) + "k"
    default:               return "\(n)"
    }
}

/// Compact USD: 3_400 -> "$3.4k", 7.7 -> "$7.70", 0 -> "$0".
public func formatCompactCost(_ usd: Double) -> String {
    guard usd != 0 else { return "$0" }
    if abs(usd) >= 1_000 { return "$" + trim(usd / 1_000) + "k" }
    return "$" + String(format: "%.2f", usd)
}

/// One decimal, but drop a trailing ".0" (3.0 -> "3", 3.4 -> "3.4").
private func trim(_ v: Double) -> String {
    let s = String(format: "%.1f", v)
    return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
}

// MARK: - Limit card (5-Hour Session / Weekly Limit)

/// One limit bar. Color grades by REMAINING capacity (reuses `CapacityLevel`).
public struct LimitCard: Equatable, Sendable {
    public enum Window: String, Equatable, Sendable { case fiveHour, weekly, weeklySonnet }
    public let window: Window
    public let title: String
    public let systemImage: String
    public let usedPercentage: Double     // 0…100; 0 when no data
    public let level: CapacityLevel
    public let resetCaption: String       // "1d 19h" / "" when unknown
    public let resetAbsolute: String       // "at 9:09 PM" / "on Mon 2:59 AM" / ""
    public let note: String               // "On track" / "limit close" / "no data"
    public let noteIsWarning: Bool
    public let hasData: Bool
    /// 5-hour session trend (nil for other cards / no history): the average and
    /// previous peak across completed 5h sessions, for the "vs avg" delta.
    public let averagePercent: Double?
    public let previousPercent: Double?

    public init(window: Window, title: String, systemImage: String,
                usedPercentage: Double, resetsAt: String?, hasData: Bool, now: Date,
                averagePercent: Double? = nil, previousPercent: Double? = nil) {
        self.window = window
        self.title = title
        self.systemImage = systemImage
        self.usedPercentage = hasData ? usedPercentage : 0
        self.hasData = hasData
        self.averagePercent = averagePercent
        self.previousPercent = previousPercent
        let remaining = max(0, 1 - usedPercentage / 100)
        self.level = !hasData ? .noData
            : (remaining > 0.5 ? .plenty : (remaining > 0.1 ? .tight : .critical))
        if hasData, let resetsAt, let date = parseISODate(resetsAt) {
            self.resetCaption = LimitCard.shortCountdown(date.timeIntervalSince(now))
            self.resetAbsolute = LimitCard.absoluteTime(date, now: now)
        } else {
            self.resetCaption = ""
            self.resetAbsolute = ""
        }
        if !hasData {
            self.note = "no data"; self.noteIsWarning = false
        } else if remaining <= 0.1 {
            self.note = "limit close"; self.noteIsWarning = true
        } else {
            self.note = "On track"; self.noteIsWarning = false
        }
    }

    /// "1d 19h" / "3h 58m" / "12m" / "resetting…".
    static func shortCountdown(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "resetting…" }
        let total = Int(seconds)
        let d = total / 86_400, h = (total % 86_400) / 3600, m = (total % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// Local clock time the window resets at: "at 9:09 PM" same day, else
    /// "on Mon 2:59 AM". Shown after the countdown (reference: "Resets in: 48m at 9:09 PM").
    static func absoluteTime(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        if Calendar.current.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "h:mm a"
            return "at " + formatter.string(from: date)
        }
        formatter.dateFormat = "EEE h:mm a"
        return "on " + formatter.string(from: date)
    }
}

// MARK: - Daily usage bar (Sun … Today)

public struct DailyUsageBar: Equatable, Sendable, Identifiable {
    public var id: Date { day }
    public let day: Date
    public let label: String          // "Sun" … "Today"
    public let totalTokens: Int
    public let cost: Double           // USD that day (for the hover detail)
    /// 0…1 relative to the week's busiest day (drives the bar colour in the view).
    public let intensity: Double

    public init(day: Date, label: String, totalTokens: Int, cost: Double = 0, intensity: Double) {
        self.day = day
        self.label = label
        self.totalTokens = totalTokens
        self.cost = cost
        self.intensity = intensity
    }
}

/// Day-of-week labels relative to `now`: today -> "Today", yesterday -> "Yest.",
/// else the abbreviated weekday ("Mon"). Deterministic (UTC, POSIX locale).
public func dailyUsageBars(_ days: [DayUsage], now: Date) -> [DailyUsageBar] {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let today = cal.startOfDay(for: now)
    let yesterday = cal.date(byAdding: .day, value: -1, to: today)
    let fmt = DateFormatter()
    fmt.calendar = cal
    fmt.timeZone = cal.timeZone
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "EEE"
    let maxTokens = days.map(\.totalTokens).max() ?? 0
    return days.map { d in
        let label: String
        if cal.isDate(d.day, inSameDayAs: today) { label = "Today" }
        else if let yesterday, cal.isDate(d.day, inSameDayAs: yesterday) { label = "Yest." }
        else { label = fmt.string(from: d.day) }
        let intensity = maxTokens > 0 ? Double(d.totalTokens) / Double(maxTokens) : 0
        return DailyUsageBar(day: d.day, label: label, totalTokens: d.totalTokens,
                             cost: d.cost, intensity: intensity)
    }
}

/// Element-wise sum of several accounts' daily buckets (matched by day). Returns
/// the longest input's day axis; missing days contribute zero.
public func mergeDailyUsage(_ perAccount: [[DayUsage]]) -> [DayUsage] {
    guard let axis = perAccount.max(by: { $0.count < $1.count }), !axis.isEmpty else { return [] }
    return axis.indices.map { i in
        var input = 0, output = 0, cache = 0; var cost = 0.0
        for days in perAccount where i < days.count {
            input += days[i].inputTokens; output += days[i].outputTokens
            cache += days[i].cacheTokens; cost += days[i].cost
        }
        return DayUsage(day: axis[i].day, inputTokens: input, outputTokens: output,
                        cacheTokens: cache, cost: cost)
    }
}

// MARK: - Current (non-stale) limit window

/// The window value to show NOW: from the most-recently-captured snapshot whose
/// that-window `resets_at` is still in the FUTURE. A `resets_at` already in the past
/// means the window has since reset, so its `used_percentage` is stale — each
/// session's statusline caches its own last-seen limits, which is exactly what
/// produced bogus readings (e.g. a stale 53%/88% next to the live 23%/5%). Falls
/// back to the latest capture's window when none are provably fresh.
public func currentWindow(_ snapshots: [UsageSnapshot],
                          _ pick: (UsageSnapshot) -> CapturedWindow?,
                          now: Date) -> CapturedWindow? {
    var best: (at: Date, window: CapturedWindow)?
    for snap in snapshots {
        guard let window = pick(snap), let capturedAt = snap.capturedAt else { continue }
        if let raw = window.resetsAt, let reset = parseISODate(raw), reset <= now { continue } // stale
        if best == nil || capturedAt > best!.at { best = (capturedAt, window) }
    }
    if let best { return best.window }
    return latestCapture(snapshots).flatMap(pick)   // nothing provably fresh
}

// MARK: - Model breakdown (token share per model)

public struct ModelShare: Equatable, Sendable, Identifiable {
    public var id: String { model }
    public let model: String
    public let percent: Double     // 0…100 of total tokens
}

/// Per-model token share across an account's sessions, highest first.
public func modelShares(_ sessions: [String: SessionUsage]) -> [ModelShare] {
    var tokensByModel: [String: Int] = [:]
    for (_, s) in sessions {
        for (model, tokens) in s.modelBreakdown { tokensByModel[model, default: 0] += tokens }
    }
    let pct = modelBreakdownPercentages(tokensByModel)
    return pct.map { ModelShare(model: $0.key, percent: $0.value) }
        .sorted { ($0.percent, $1.model) > ($1.percent, $0.model) }
}

// MARK: - Token usage table (Today / This Month)

public struct TokenRow: Equatable, Sendable, Identifiable {
    public var id: String { period }
    public let period: String
    public let input: Int
    public let output: Int
    public let cache: Int
    public let cost: Double
}

public func tokenRows(today: UsageTotals, thisMonth: UsageTotals) -> [TokenRow] {
    func row(_ period: String, _ t: UsageTotals) -> TokenRow {
        TokenRow(period: period, input: t.inputTokens, output: t.outputTokens,
                 cache: t.cacheReadTokens + t.cacheWriteTokens, cost: t.cost)
    }
    return [row("Today", today), row("Month", thisMonth)]
}

// MARK: - One dashboard column (Overall, or one account)

public struct DashboardColumn: Equatable, Sendable, Identifiable {
    public var id: String { title }
    public let title: String
    public let fiveHour: LimitCard
    public let weekly: LimitCard
    /// 7-day Sonnet limit (reference's "Weekly Sonnet"). Rendered only when it has
    /// data — its source (OAuth) may be unavailable.
    public let weeklySonnet: LimitCard
    public let daily: [DailyUsageBar]
    public let models: [ModelShare]
    public let tokens: [TokenRow]
    public let costToday: Double
    public let costMonth: Double
}

/// 5-hour session trend from the capture history: the average and previous PEAK
/// used-% across COMPLETED 5h sessions (windows whose reset is already past).
/// Captures are grouped by their reset instant (rounded to 10 min to absorb
/// epoch-vs-ISO formatting differences between statusline and OAuth sources).
public func fiveHourSessionTrend(_ snapshots: [UsageSnapshot], now: Date)
    -> (previous: Double?, average: Double?) {
    var peakByWindow: [Int: (reset: Date, peak: Double)] = [:]
    for snap in snapshots {
        guard let w = snap.fiveHour, let raw = w.resetsAt, let reset = parseISODate(raw) else { continue }
        let bucket = Int((reset.timeIntervalSince1970 / 600).rounded())
        peakByWindow[bucket] = (reset, max(peakByWindow[bucket]?.peak ?? 0, w.usedPercentage))
    }
    let completed = peakByWindow.values.filter { $0.reset <= now }.sorted { $0.reset < $1.reset }
    guard !completed.isEmpty else { return (nil, nil) }
    let average = completed.map(\.peak).reduce(0, +) / Double(completed.count)
    return (completed.last?.peak, average)
}

/// Most-recent capture of an account's snapshot list (by capturedAt).
func latestCapture(_ snapshots: [UsageSnapshot]) -> UsageSnapshot? {
    snapshots.max { ($0.capturedAt ?? .distantPast) < ($1.capturedAt ?? .distantPast) }
}

/// Builds one account's dashboard column from its analytics + captures.
public func accountDashboard(name: String, analytics: AccountUsageAnalytics?,
                             snapshots: [UsageSnapshot], now: Date) -> DashboardColumn {
    let fh = currentWindow(snapshots, { $0.fiveHour }, now: now)
    let wk = currentWindow(snapshots, { $0.sevenDay }, now: now)
    let sonnet = currentWindow(snapshots, { $0.sevenDaySonnet }, now: now)
    let trend = fiveHourSessionTrend(snapshots, now: now)
    let five = LimitCard(window: .fiveHour, title: "5-Hour Session", systemImage: "clock",
                         usedPercentage: fh?.usedPercentage ?? 0, resetsAt: fh?.resetsAt,
                         hasData: fh != nil, now: now,
                         averagePercent: trend.average, previousPercent: trend.previous)
    let weekly = LimitCard(window: .weekly, title: "Weekly Limit", systemImage: "calendar",
                           usedPercentage: wk?.usedPercentage ?? 0, resetsAt: wk?.resetsAt,
                           hasData: wk != nil, now: now)
    let weeklySonnet = LimitCard(window: .weeklySonnet, title: "Weekly Sonnet", systemImage: "calendar.badge.clock",
                                 usedPercentage: sonnet?.usedPercentage ?? 0, resetsAt: sonnet?.resetsAt,
                                 hasData: sonnet != nil, now: now)
    return DashboardColumn(
        title: name,
        fiveHour: five,
        weekly: weekly,
        weeklySonnet: weeklySonnet,
        daily: dailyUsageBars(analytics?.daily ?? [], now: now),
        models: modelShares(analytics?.sessions ?? [:]),
        tokens: tokenRows(today: analytics?.today ?? UsageTotals(),
                          thisMonth: analytics?.thisMonth ?? UsageTotals()),
        costToday: analytics?.today.cost ?? 0,
        costMonth: analytics?.thisMonth.cost ?? 0)
}

/// Builds the "Overall" column: limit bars from the tier-weighted aggregates,
/// daily/models/tokens summed across accounts.
public func overallDashboard(analyticsByAccount: [String: AccountUsageAnalytics],
                             snapshotsByAccount: [String: [UsageSnapshot]],
                             aggregateFiveHour: RateLimitModel.Aggregate,
                             aggregateWeekly: RateLimitModel.Aggregate,
                             aggregateSonnet: RateLimitModel.Aggregate,
                             now: Date) -> DashboardColumn {
    let allCaptures = snapshotsByAccount.values.flatMap { $0 }
    // Aggregate limit "used%" = 1 - tier-weighted remaining fraction.
    let fiveUsed = aggregateFiveHour.total > 0 ? (1 - aggregateFiveHour.fraction) * 100 : 0
    let weeklyUsed = aggregateWeekly.total > 0 ? (1 - aggregateWeekly.fraction) * 100 : 0
    let sonnetUsed = aggregateSonnet.total > 0 ? (1 - aggregateSonnet.fraction) * 100 : 0
    // Soonest reset across accounts for each window (most urgent shown).
    let fiveReset = soonestReset(allCaptures.compactMap { $0.fiveHour }, now: now)
    let weeklyReset = soonestReset(allCaptures.compactMap { $0.sevenDay }, now: now)
    let sonnetReset = soonestReset(allCaptures.compactMap { $0.sevenDaySonnet }, now: now)
    let trend = fiveHourSessionTrend(allCaptures, now: now)
    let five = LimitCard(window: .fiveHour, title: "5-Hour Session", systemImage: "clock",
                         usedPercentage: fiveUsed, resetsAt: fiveReset,
                         hasData: aggregateFiveHour.total > 0, now: now,
                         averagePercent: trend.average, previousPercent: trend.previous)
    let weekly = LimitCard(window: .weekly, title: "Weekly Limit", systemImage: "calendar",
                           usedPercentage: weeklyUsed, resetsAt: weeklyReset,
                           hasData: aggregateWeekly.total > 0, now: now)
    let weeklySonnet = LimitCard(window: .weeklySonnet, title: "Weekly Sonnet", systemImage: "calendar.badge.clock",
                                 usedPercentage: sonnetUsed, resetsAt: sonnetReset,
                                 hasData: aggregateSonnet.total > 0, now: now)

    let mergedDaily = mergeDailyUsage(analyticsByAccount.values.map { $0.daily })
    var allSessions: [String: SessionUsage] = [:]
    for (_, a) in analyticsByAccount { for (k, v) in a.sessions { allSessions[k] = v } }
    let today = sumTotals(analyticsByAccount.values.map { $0.today })
    let month = sumTotals(analyticsByAccount.values.map { $0.thisMonth })

    return DashboardColumn(
        title: "Overall",
        fiveHour: five,
        weekly: weekly,
        weeklySonnet: weeklySonnet,
        daily: dailyUsageBars(mergedDaily, now: now),
        models: modelShares(allSessions),
        tokens: tokenRows(today: today, thisMonth: month),
        costToday: today.cost,
        costMonth: month.cost)
}

/// The window whose reset is soonest in the future (raw ISO string), or nil.
func soonestReset(_ windows: [CapturedWindow], now: Date) -> String? {
    windows
        .compactMap { w -> (String, Date)? in
            guard let raw = w.resetsAt, let date = parseISODate(raw), date > now else { return nil }
            return (raw, date)
        }
        .min { $0.1 < $1.1 }?.0
}

func sumTotals(_ totals: [UsageTotals]) -> UsageTotals {
    var out = UsageTotals()
    for t in totals {
        out.inputTokens += t.inputTokens
        out.outputTokens += t.outputTokens
        out.cacheReadTokens += t.cacheReadTokens
        out.cacheWrite5mTokens += t.cacheWrite5mTokens
        out.cacheWrite1hTokens += t.cacheWrite1hTokens
        out.cost += t.cost
    }
    return out
}
