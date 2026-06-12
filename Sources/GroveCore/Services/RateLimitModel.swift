import Foundation

/// Tier-weighted rate-limit math (spec §C.3). Pure: every time-dependent value
/// takes an injected `now` (no Date()). The single tier->weight table lives here.
public enum RateLimitModel {
    public struct Weight: Sendable, Equatable {
        public let value: Double
        public let isUnknown: Bool
    }

    /// organizationRateLimitTier -> relative capacity weight. The ONE place to
    /// maintain these numbers (spec §C.3 open item). Unknown/nil -> 1, flagged.
    public static let tierWeights: [String: Double] = [
        "default_claude_max_20x": 20,
        "default_claude_max_5x": 5,
        "default_claude_pro": 1,
    ]

    public static func weight(forTier tier: String?) -> Weight {
        guard let tier, let value = tierWeights[tier] else { return Weight(value: 1, isUnknown: true) }
        return Weight(value: value, isUnknown: false)
    }

    /// One window's derived status. remainingFraction = 1 - used%/100.
    public struct WindowStatus: Sendable, Equatable {
        public let usedPercentage: Double
        public let remainingFraction: Double
        public let resetsIn: TimeInterval?   // nil when resets_at absent/unparseable
        public let isExpired: Bool           // resets_at already in the past
    }

    public static func window(usedPercentage: Double, resetsAt: String?, now: Date) -> WindowStatus {
        let remainingFraction = max(0, 1 - usedPercentage / 100)
        let resetDate = resetsAt.flatMap(gitISODate)
        let resetsIn = resetDate.map { $0.timeIntervalSince(now) }
        let isExpired = resetDate.map { $0 <= now } ?? false
        return WindowStatus(usedPercentage: usedPercentage,
                            remainingFraction: remainingFraction,
                            resetsIn: resetsIn,
                            isExpired: isExpired)
    }

    /// One account's contribution to an aggregate window.
    public struct AccountWindow: Sendable, Equatable {
        public let tier: String?
        public let usedPercentage: Double
        public init(tier: String?, usedPercentage: Double) {
            self.tier = tier; self.usedPercentage = usedPercentage
        }
    }

    public struct Aggregate: Sendable, Equatable {
        public let remaining: Double
        public let total: Double
        public var fraction: Double { total == 0 ? 0 : remaining / total }
        // Public init so cross-module callers/tests (e.g. AggregateBadge's no-data
        // grade, FIX I4) can construct an Aggregate directly.
        public init(remaining: Double, total: Double) {
            self.remaining = remaining
            self.total = total
        }
    }

    /// Aggregate remaining = Σ weight·(1 − used%/100); total = Σ weight (spec §C.3).
    public static func aggregateRemaining(_ accounts: [AccountWindow]) -> Aggregate {
        var remaining = 0.0
        var total = 0.0
        for account in accounts {
            let w = weight(forTier: account.tier).value
            remaining += w * max(0, 1 - account.usedPercentage / 100)
            total += w
        }
        return Aggregate(remaining: remaining, total: total)
    }
}
