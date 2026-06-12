import Foundation
import GroveCore

/// Capacity grade. `.noData` (FIX I4) is the NEUTRAL state when there are zero
/// usage captures — distinct from `.critical` so the badge renders gray, not red.
public enum CapacityLevel: Sendable, Equatable { case noData, plenty, tight, critical }

/// View model for one 5h/7d limit bar. Color grades by REMAINING (1 - used%).
public struct LimitBar: Sendable, Equatable {
    public let usedPercentage: Double
    public let level: CapacityLevel
    public let resetCaption: String

    public init(usedPercentage: Double, resetsAt: String?, now: Date) {
        self.usedPercentage = usedPercentage
        let remaining = max(0, 1 - usedPercentage / 100)
        self.level = remaining > 0.5 ? .plenty : (remaining > 0.1 ? .tight : .critical)
        if let resetsAt, let date = parseISODate(resetsAt) {
            self.resetCaption = LimitBar.countdown(date.timeIntervalSince(now))
        } else { self.resetCaption = "" }
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "resetting…" }
        let h = Int(seconds) / 3600, m = (Int(seconds) % 3600) / 60
        return h > 0 ? "resets in \(h)h \(m)m" : "resets in \(m)m"
    }
}

/// total-token share per model id (0…100). Empty input -> empty (no divide-by-zero).
public func modelBreakdownPercentages(_ tokensByModel: [String: Int]) -> [String: Double] {
    let total = tokensByModel.values.reduce(0, +)
    guard total > 0 else { return [:] }
    return tokensByModel.mapValues { Double($0) / Double(total) * 100 }
}

/// The global remaining-capacity badge color grade (Task 10's header chip uses it).
/// FIX I4: `hasData == false` (zero captures) grades `.noData` (neutral/gray),
/// NEVER `.critical` — so existing snapshot scenes with no fixture captures don't
/// all turn red. Construct from an Aggregate (whose `total == 0` means no data) or,
/// for direct fraction tests, from a fraction with `hasData: true`.
public struct AggregateBadge: Sendable, Equatable {
    public let fraction: Double
    public let hasData: Bool
    public var level: CapacityLevel {
        guard hasData else { return .noData }
        return fraction > 0.5 ? .plenty : (fraction > 0.1 ? .tight : .critical)
    }
    public init(fraction: Double, hasData: Bool = true) {
        self.fraction = fraction
        self.hasData = hasData
    }
    /// From an aggregate: `total == 0` (no captures) -> no data (neutral).
    public init(_ aggregate: RateLimitModel.Aggregate) {
        self.init(fraction: aggregate.fraction, hasData: aggregate.total > 0)
    }
}
