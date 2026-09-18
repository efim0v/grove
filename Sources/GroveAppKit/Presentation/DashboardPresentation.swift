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

/// Capacity grade from a used-percentage. The ONE place these thresholds live —
/// `LimitCard`, the per-account chips and the menu-bar readout all grade alike.
public func capacityLevel(usedPercentage: Double) -> CapacityLevel {
    let remaining = max(0, 1 - usedPercentage / 100)
    return remaining > 0.5 ? .plenty : (remaining > 0.1 ? .tight : .critical)
}

/// One account's contribution to an "Overall" bar, rendered as a chip under it
/// ("work 12% · personal 56%"). Answers *which* account has headroom left, which
/// the tier-weighted aggregate alone cannot.
public struct AccountLimitChip: Equatable, Sendable, Identifiable {
    public var id: String { account }
    public let account: String
    public let usedPercentage: Double
    public let level: CapacityLevel

    public init(account: String, usedPercentage: Double) {
        self.account = account
        self.usedPercentage = usedPercentage
        self.level = capacityLevel(usedPercentage: usedPercentage)
    }
}

/// One limit bar. Color grades by REMAINING capacity (reuses `CapacityLevel`).
public struct LimitCard: Equatable, Sendable {
    public enum Window: String, Equatable, Sendable { case fiveHour, weekly, weeklySonnet, weeklyModel }
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
    /// Per-account breakdown of this bar, populated for the "Overall" scope only —
    /// a single account's own column has nothing to break down. Sorted by load
    /// descending (the account closest to its limit reads first).
    public let perAccount: [AccountLimitChip]

    public init(window: Window, title: String, systemImage: String,
                usedPercentage: Double, resetsAt: String?, hasData: Bool, now: Date,
                averagePercent: Double? = nil, previousPercent: Double? = nil,
                perAccount: [AccountLimitChip] = []) {
        self.window = window
        self.title = title
        self.systemImage = systemImage
        self.usedPercentage = hasData ? usedPercentage : 0
        self.hasData = hasData
        self.averagePercent = averagePercent
        self.previousPercent = previousPercent
        self.perAccount = perAccount
        let remaining = max(0, 1 - usedPercentage / 100)
        self.level = !hasData ? .noData : capacityLevel(usedPercentage: usedPercentage)
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
    // Bar height/intensity is driven by COST, not tokens: recent days come from the snapshot
    // ledger which only has cost, so the whole axis must be cost to be one consistent metric.
    let maxCost = days.map(\.cost).max() ?? 0
    return days.map { d in
        let label: String
        if cal.isDate(d.day, inSameDayAs: today) { label = "Today" }
        else if let yesterday, cal.isDate(d.day, inSameDayAs: yesterday) { label = "Yest." }
        else { label = fmt.string(from: d.day) }
        let intensity = maxCost > 0 ? d.cost / maxCost : 0
        return DailyUsageBar(day: d.day, label: label, totalTokens: d.totalTokens,
                             cost: d.cost, intensity: intensity)
    }
}

/// Overrides each day's transcript-derived cost with the snapshot ledger's tracked cost-delta for
/// the days Grove has actually recorded (membership of the day key in `ledgerCostByDay` IS the
/// "Grove tracked this day" signal). Untracked days (pre-tracking / gaps) keep their transcript
/// cost. Tokens are carried through unchanged (only the cost metric is corrected). One consistent
/// USD-per-day series for `dailyUsageBars` to render.
public func mergeLedgerCost(_ daily: [DayUsage], ledgerCostByDay: [Date: Double]) -> [DayUsage] {
    daily.map { d in
        guard let tracked = ledgerCostByDay[d.day] else { return d }
        return DayUsage(day: d.day, inputTokens: d.inputTokens, outputTokens: d.outputTokens,
                        cacheTokens: d.cacheTokens, cost: tracked)
    }
}

/// Sum of several accounts' daily buckets, matched BY DAY. Returns the longest
/// input's day axis; a day an account has no bucket for contributes zero.
///
/// Matching by day rather than by array position: today every account is built from
/// the same fixed 7-day UTC axis, so the two agree — but the axis is not a contract,
/// and a positional sum would silently add Monday to Tuesday the moment it varies.
public func mergeDailyUsage(_ perAccount: [[DayUsage]]) -> [DayUsage] {
    guard let axis = perAccount.max(by: { $0.count < $1.count }), !axis.isEmpty else { return [] }
    var byDay: [Date: (input: Int, output: Int, cache: Int, cost: Double)] = [:]
    for days in perAccount {
        for d in days {
            var bucket = byDay[d.day] ?? (0, 0, 0, 0)
            bucket.input += d.inputTokens; bucket.output += d.outputTokens
            bucket.cache += d.cacheTokens; bucket.cost += d.cost
            byDay[d.day] = bucket
        }
    }
    return axis.map { slot in
        let bucket = byDay[slot.day] ?? (0, 0, 0, 0)
        return DayUsage(day: slot.day, inputTokens: bucket.input, outputTokens: bucket.output,
                        cacheTokens: bucket.cache, cost: bucket.cost)
    }
}

// MARK: - "Updated …" footer

/// When the displayed limits were last really obtained, e.g. "25 Jul 14:32". "—"
/// when nothing has been captured yet. Locale/timezone are injected so the format
/// is testable and matches the user's clock in production.
public func formatAsOf(_ date: Date?, locale: Locale = .current,
                       timeZone: TimeZone = .current) -> String {
    guard let date else { return "—" }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
    return formatter.string(from: date)
}

// MARK: - Current (non-stale) limit window

/// The window value to show NOW: from the most-recently-captured snapshot whose
/// that-window `resets_at` is still in the FUTURE. A `resets_at` already in the past
/// means the window has since reset, so its `used_percentage` is stale — each
/// session's statusline caches its own last-seen limits, which is exactly what
/// produced bogus readings (e.g. a stale 53%/88% next to the live 23%/5%). Falls
/// back to the latest capture's window when none are provably fresh.
/// THE resolver — every scope uses this one, which is the point. Overall's bars and
/// chips used to go through a second resolver that preferred statusline captures over
/// OAuth ones whenever the statusline's window had not yet reset. But "has not reset"
/// is not "was captured recently": the statusline only re-renders when a session
/// redraws, so a reading minutes old routinely masked the OAuth reading fetched on
/// panel open — and "Overall" then disagreed with the very same account's own column
/// (the reported 81% vs 83%). Recency is the only defensible tie-break: whoever
/// measured last measured best, whatever the source.
///
/// Snapshots that don't carry this window are ignored entirely, which is what lets an
/// account whose statusline emits no `rate_limits` still resolve from OAuth alone.
public func currentWindow(_ snapshots: [UsageSnapshot],
                          _ pick: (UsageSnapshot) -> CapturedWindow?,
                          now: Date) -> CapturedWindow? {
    var newestValid: (at: Date, window: CapturedWindow)?
    var newestAny: (at: Date, window: CapturedWindow)?
    for snap in snapshots {
        guard let window = pick(snap), let capturedAt = snap.capturedAt else { continue }
        if newestAny == nil || capturedAt > newestAny!.at { newestAny = (capturedAt, window) }
        // A window whose reset has passed reports usage from a period that has since
        // rolled over, so its percentage is meaningless — it can only serve as a
        // last-known value when nothing still-valid exists.
        let hasReset = window.resetsAt.flatMap(parseISODate).map { $0 <= now } ?? false
        guard !hasReset else { continue }
        if newestValid == nil || capturedAt > newestValid!.at { newestValid = (capturedAt, window) }
    }
    return (newestValid ?? newestAny)?.window
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

/// Renders a token count for display: 0 (genuinely absent data) becomes "—" (em-dash);
/// non-zero values use the same compact formatter as other numeric cells ("1.2k", "3M", …).
/// Presentationally honest: a real zero-token day is equally uninformative and equally "—".
public func tokenCellText(count: Int) -> String {
    count == 0 ? "—" : formatCompactTokens(count)
}

/// UTC start-of-day cost from a ledger (0 if the day is absent).
public func ledgerTodayCost(ledger: UsageCostLedger, now: Date) -> Double {
    let today = UsageCostLedger.utcCalendar.startOfDay(for: now)
    return ledger.cost(on: today)
}

/// Sum of all ledger days that fall within the same UTC calendar month as `now`.
public func ledgerMonthCost(ledger: UsageCostLedger, now: Date) -> Double {
    ledger.days.filter { isInSameUTCMonth($0.day, as: now) }.reduce(0) { $0 + $1.costUSD }
}

/// True when `date` falls in the same UTC year+month as `now`.
func isInSameUTCMonth(_ date: Date, as now: Date) -> Bool {
    let cal = UsageCostLedger.utcCalendar
    let dc = cal.dateComponents([.year, .month], from: date)
    let nc = cal.dateComponents([.year, .month], from: now)
    return dc.year == nc.year && dc.month == nc.month
}

public func tokenRows(today: UsageTotals, thisMonth: UsageTotals,
                      ledgerTodayCost: Double? = nil, ledgerMonthCost: Double? = nil) -> [TokenRow] {
    func effectiveCost(_ transcriptCost: Double, _ ledgerCost: Double?) -> Double {
        transcriptCost > 0 ? transcriptCost : (ledgerCost ?? transcriptCost)
    }
    func row(_ period: String, _ t: UsageTotals, _ ledgerCost: Double?) -> TokenRow {
        TokenRow(period: period, input: t.inputTokens, output: t.outputTokens,
                 cache: t.cacheReadTokens + t.cacheWriteTokens,
                 cost: effectiveCost(t.cost, ledgerCost))
    }
    return [row("Today", today, ledgerTodayCost), row("Month", thisMonth, ledgerMonthCost)]
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
    /// 7-day model-specific limits (Weekly Opus / Weekly Fable / Weekly Sonnet). An
    /// account column carries at most ONE — its active model's, resolved from the
    /// latest capture. "Overall" carries one per DISTINCT model across accounts, each
    /// aggregating only the accounts on that model: averaging an Opus account into a
    /// Fable bar would state a limit that no account actually has. Empty when the
    /// source (OAuth) is unavailable.
    public let weeklyModels: [LimitCard]
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

// MARK: - Model-specific weekly window

/// Maps the active model to the dedicated 7-day limit window and its card title.
///
/// Priority:
///   1. OAuth `limits[]` `weekly_scoped` entry (from `weeklyScopedWindow`/`weeklyScopedModel`
///      on the synthetic OAuth snapshot). Title = "Weekly \(modelDisplayName)" (e.g.
///      "Weekly Fable"). This is the PRIMARY source — it always carries the right model
///      name from the live API response regardless of local model-id prefix matching.
///   2. Fall back to the legacy per-model top-level fields keyed off `latestModelId` prefix:
///      - `claude-opus-*`   → "Weekly Opus"  / sevenDayOpus
///      - `claude-fable-*`  → "Weekly Fable" / sevenDayFable
///      - `claude-sonnet-*` → "Weekly Sonnet"/ sevenDaySonnet
///   3. Unknown / nil model id → title "Weekly Model", window nil (card hidden via hasData=false)
///
/// The active model for the fallback path is resolved from the latest NON-oauth snapshot
/// that carries a modelId (statusline captures set the model; the synthetic "oauth" capture
/// has modelId==nil). The window value itself is read from `currentWindow` across ALL
/// snapshots for both paths.
///
/// For "Overall" (multi-account), pass all snapshots merged: the most-recent live model
/// determines the family; the window value is picked from the same merged set.
public func modelWindow(latestModelId: String?, snapshots: [UsageSnapshot], now: Date)
    -> (title: String, window: CapturedWindow?) {
    // 1. PRIMARY: OAuth limits[]-derived model-scoped window.
    //    The oauth snapshot carries weeklyScopedWindow + weeklyScopedModel.
    if let scopedModel = currentWeeklyScopedModel(snapshots, now: now),
       let scopedWindow = currentWindow(snapshots, { $0.weeklyScopedWindow }, now: now) {
        return ("Weekly \(scopedModel)", scopedWindow)
    }

    // 2. FALLBACK: legacy per-model top-level fields keyed off model-id prefix.
    let baseId = latestModelId.map { id -> String in
        if let bracket = id.firstIndex(of: "[") { return String(id[..<bracket]) }
        return id
    }
    switch baseId {
    case let id? where id.hasPrefix("claude-opus-"):
        return ("Weekly Opus",   currentWindow(snapshots, { $0.sevenDayOpus },   now: now))
    case let id? where id.hasPrefix("claude-fable-"):
        return ("Weekly Fable",  currentWindow(snapshots, { $0.sevenDayFable },  now: now))
    case let id? where id.hasPrefix("claude-sonnet-"):
        return ("Weekly Sonnet", currentWindow(snapshots, { $0.sevenDaySonnet }, now: now))
    default:
        return ("Weekly Model", nil)
    }
}

/// Returns the model display name from the most-recently-captured fresh OAuth snapshot
/// that carries a `weeklyScopedModel`. Used by `modelWindow` as the PRIMARY source for
/// the bar title.
private func currentWeeklyScopedModel(_ snapshots: [UsageSnapshot], now: Date) -> String? {
    var best: (at: Date, model: String)?
    for snap in snapshots {
        guard let model = snap.weeklyScopedModel,
              let window = snap.weeklyScopedWindow,
              let capturedAt = snap.capturedAt else { continue }
        // Skip stale windows.
        if let raw = window.resetsAt, let reset = parseISODate(raw), reset <= now { continue }
        if best == nil || capturedAt > best!.at { best = (capturedAt, model) }
    }
    if let best { return best.model }
    // Fallback: any snapshot with a scoped model (even stale), matching latestCapture behaviour.
    return latestCapture(snapshots.filter { $0.weeklyScopedModel != nil })?.weeklyScopedModel
}

/// Resolves the active model id from the most-recent NON-oauth snapshot that carries one.
/// OAuth snapshots are synthetic and never carry a modelId; statusline ones do.
func resolveLatestModelId(_ snapshots: [UsageSnapshot]) -> String? {
    let statusline = snapshots.filter { $0.sessionId != "oauth" }
    return latestCapture(statusline)?.modelId
}

/// Like `modelWindow`, but yields the model DISPLAY NAME alongside the window and
/// only when both exist — the shape "Overall" needs to group accounts by model.
/// `modelWindow` deliberately still reports a title for a known model with no window
/// (so a hidden card keeps its identity); grouping has nothing to group there.
public func modelScopedWindow(latestModelId: String?, snapshots: [UsageSnapshot], now: Date)
    -> (model: String, window: CapturedWindow)? {
    let resolved = modelWindow(latestModelId: latestModelId, snapshots: snapshots, now: now)
    guard let window = resolved.window else { return nil }
    let prefix = "Weekly "
    let model = resolved.title.hasPrefix(prefix)
        ? String(resolved.title.dropFirst(prefix.count)) : resolved.title
    return (model, window)
}

/// SF Symbol for the model-specific weekly card based on the resolved title.
func modelSystemImage(_ title: String) -> String {
    switch title {
    case "Weekly Opus":   return "o.circle.fill"
    case "Weekly Fable":  return "f.circle.fill"
    case "Weekly Sonnet": return "s.circle.fill"
    default:              return "m.circle.fill"
    }
}

/// Builds one account's dashboard column from its analytics + captures.
public func accountDashboard(name: String, analytics: AccountUsageAnalytics?,
                             snapshots: [UsageSnapshot], now: Date,
                             ledgerCostByDay: [Date: Double] = [:]) -> DashboardColumn {
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
    let weeklySonnet = LimitCard(window: .weeklySonnet, title: "Weekly Sonnet", systemImage: "s.circle.fill",
                                 usedPercentage: sonnet?.usedPercentage ?? 0, resetsAt: sonnet?.resetsAt,
                                 hasData: sonnet != nil, now: now)
    let activeModelId = resolveLatestModelId(snapshots)
    let mw = modelWindow(latestModelId: activeModelId, snapshots: snapshots, now: now)
    // An account runs ONE model at a time, so its column carries at most one model
    // bar — and none at all when the window is missing (the card was hidden anyway).
    let weeklyModelCards: [LimitCard] = mw.window.map { window in
        [LimitCard(window: .weeklyModel, title: mw.title,
                   systemImage: modelSystemImage(mw.title),
                   usedPercentage: window.usedPercentage, resetsAt: window.resetsAt,
                   hasData: true, now: now)]
    } ?? []
    let todayKey = UsageCostLedger.utcCalendar.startOfDay(for: now)
    let lTodayCost: Double? = ledgerCostByDay.isEmpty ? nil : ledgerCostByDay[todayKey]
    let lMonthCost: Double? = ledgerCostByDay.isEmpty ? nil
        : ledgerCostByDay.filter { isInSameUTCMonth($0.key, as: now) }.values.reduce(0, +)
    return DashboardColumn(
        title: name,
        fiveHour: five,
        weekly: weekly,
        weeklySonnet: weeklySonnet,
        weeklyModels: weeklyModelCards,
        daily: dailyUsageBars(mergeLedgerCost(analytics?.daily ?? [], ledgerCostByDay: ledgerCostByDay), now: now),
        models: modelShares(analytics?.sessions ?? [:]),
        tokens: tokenRows(today: analytics?.today ?? UsageTotals(),
                          thisMonth: analytics?.thisMonth ?? UsageTotals(),
                          ledgerTodayCost: lTodayCost, ledgerMonthCost: lMonthCost),
        costToday: analytics?.today.cost ?? 0,
        costMonth: analytics?.thisMonth.cost ?? 0)
}

/// One account's resolved limit windows plus its tier — the SINGLE input to every
/// "Overall" aggregate. Both the panel and the menu-bar readout are computed from
/// this same list, so the two numbers cannot drift apart.
public struct AccountLimitInput: Equatable, Sendable {
    public let account: String
    public let tier: String?
    public let fiveHour: CapturedWindow?
    public let weekly: CapturedWindow?
    public let weeklySonnet: CapturedWindow?
    /// Display name of the account's active model ("Fable", "Opus"), when known.
    public let scopedModel: String?
    public let scopedWindow: CapturedWindow?

    public init(account: String, tier: String?, fiveHour: CapturedWindow?,
                weekly: CapturedWindow?, weeklySonnet: CapturedWindow?,
                scopedModel: String?, scopedWindow: CapturedWindow?) {
        self.account = account
        self.tier = tier
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.weeklySonnet = weeklySonnet
        self.scopedModel = scopedModel
        self.scopedWindow = scopedWindow
    }
}

/// The tier-weighted bar for one window across a set of accounts, plus the chips
/// naming each contributor. Accounts without that window drop out entirely — they
/// have nothing to say about it, and counting them as 0% would understate the load.
func aggregateCard(window: LimitCard.Window, title: String, systemImage: String,
                   inputs: [AccountLimitInput], pick: (AccountLimitInput) -> CapturedWindow?,
                   now: Date, averagePercent: Double? = nil,
                   previousPercent: Double? = nil) -> LimitCard {
    let contributors = inputs.compactMap { input -> (AccountLimitInput, CapturedWindow)? in
        guard let window = pick(input) else { return nil }
        return (input, window)
    }
    let aggregate = RateLimitModel.aggregateRemaining(contributors.map {
        RateLimitModel.AccountWindow(tier: $0.0.tier, usedPercentage: $0.1.usedPercentage)
    })
    let used = aggregate.total > 0 ? (1 - aggregate.fraction) * 100 : 0
    // The SOONEST future reset: the next moment any account's headroom returns.
    let reset = soonestReset(contributors.map(\.1), now: now)
    let chips = contributors
        .map { AccountLimitChip(account: $0.0.account, usedPercentage: $0.1.usedPercentage) }
        .sorted { ($0.usedPercentage, $1.account) > ($1.usedPercentage, $0.account) }
    return LimitCard(window: window, title: title, systemImage: systemImage,
                     usedPercentage: used, resetsAt: reset, hasData: aggregate.total > 0,
                     now: now, averagePercent: averagePercent, previousPercent: previousPercent,
                     perAccount: chips)
}

/// One bar per DISTINCT active model across accounts, each aggregating only the
/// accounts on that model. Ordered by group size descending (the model most accounts
/// run leads), then by title — a total order, so the layout never reshuffles.
func modelCards(_ inputs: [AccountLimitInput], now: Date) -> [LimitCard] {
    var byModel: [String: [AccountLimitInput]] = [:]
    for input in inputs {
        guard let model = input.scopedModel, input.scopedWindow != nil else { continue }
        byModel[model, default: []].append(input)
    }
    return byModel
        .map { model, group -> (count: Int, card: LimitCard) in
            let title = "Weekly \(model)"
            return (group.count,
                    aggregateCard(window: .weeklyModel, title: title,
                                  systemImage: modelSystemImage(title),
                                  inputs: group, pick: { $0.scopedWindow }, now: now))
        }
        .sorted { ($0.count, $1.card.title) > ($1.count, $0.card.title) }
        .map(\.card)
}

/// Builds the "Overall" column: limit bars from the tier-weighted aggregates over
/// `limitInputs`, daily/models/tokens summed across accounts.
public func overallDashboard(analyticsByAccount: [String: AccountUsageAnalytics],
                             snapshotsByAccount: [String: [UsageSnapshot]],
                             limitInputs: [AccountLimitInput],
                             now: Date,
                             ledgerCostByAccount: [String: [Date: Double]] = [:]) -> DashboardColumn {
    let allCaptures = snapshotsByAccount.values.flatMap { $0 }
    let trend = fiveHourSessionTrend(allCaptures, now: now)
    let five = aggregateCard(window: .fiveHour, title: "5-Hour Session", systemImage: "clock",
                             inputs: limitInputs, pick: { $0.fiveHour }, now: now,
                             averagePercent: trend.average, previousPercent: trend.previous)
    let weekly = aggregateCard(window: .weekly, title: "Weekly Limit", systemImage: "calendar",
                               inputs: limitInputs, pick: { $0.weekly }, now: now)
    let weeklySonnet = aggregateCard(window: .weeklySonnet, title: "Weekly Sonnet",
                                     systemImage: "s.circle.fill",
                                     inputs: limitInputs, pick: { $0.weeklySonnet }, now: now)
    let weeklyModelCards = modelCards(limitInputs, now: now)

    // Ledger-correct each account's daily COST before summing, so the overall bar height (cost)
    // reflects the snapshot-tracked recent days, not the empty transcript days.
    let mergedDaily = mergeDailyUsage(analyticsByAccount.map { name, a in
        mergeLedgerCost(a.daily, ledgerCostByDay: ledgerCostByAccount[name] ?? [:])
    })
    var allSessions: [String: SessionUsage] = [:]
    for (_, a) in analyticsByAccount { for (k, v) in a.sessions { allSessions[k] = v } }
    let today = sumTotals(analyticsByAccount.values.map { $0.today })
    let month = sumTotals(analyticsByAccount.values.map { $0.thisMonth })

    // Sum ledger costs across ALL accounts for the overall column.
    let allLedgerByDay: [Date: Double] = ledgerCostByAccount.values.reduce(into: [:]) { acc, dict in
        for (day, cost) in dict { acc[day, default: 0] += cost }
    }
    let todayKey = UsageCostLedger.utcCalendar.startOfDay(for: now)
    let lTodayCost: Double? = allLedgerByDay.isEmpty ? nil : allLedgerByDay[todayKey]
    let lMonthCost: Double? = allLedgerByDay.isEmpty ? nil
        : allLedgerByDay.filter { isInSameUTCMonth($0.key, as: now) }.values.reduce(0, +)

    return DashboardColumn(
        title: "Overall",
        fiveHour: five,
        weekly: weekly,
        weeklySonnet: weeklySonnet,
        weeklyModels: weeklyModelCards,
        daily: dailyUsageBars(mergedDaily, now: now),
        models: modelShares(allSessions),
        tokens: tokenRows(today: today, thisMonth: month,
                          ledgerTodayCost: lTodayCost, ledgerMonthCost: lMonthCost),
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
