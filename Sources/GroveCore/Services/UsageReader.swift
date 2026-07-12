import Foundation

/// One window's captured limit (from statusline rate_limits.{five_hour,seven_day}).
public struct CapturedWindow: Sendable, Equatable {
    public let usedPercentage: Double
    public let resetsAt: String?   // raw ISO8601; RateLimitModel parses it
    // Public init so cross-module callers/tests can construct a window directly.
    public init(usedPercentage: Double, resetsAt: String?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }
}

/// A trimmed statusline capture snapshot for one session (spec §C.1). All optional
/// fields degrade to nil — `rate_limits` is frequently ABSENT.
public struct UsageSnapshot: Sendable, Equatable {
    public let accountName: String
    public let sessionId: String
    public let capturedAt: Date?
    public let cwd: String?
    public let modelId: String?
    public let modelDisplayName: String?
    public let effort: String?
    public let contextUsedPercentage: Double?
    public let totalInputTokens: Int?
    public let totalCostUSD: Double?
    public let fiveHour: CapturedWindow?
    public let sevenDay: CapturedWindow?
    /// 7-day Sonnet-specific window. The statusline never emits it; it's populated
    /// from Anthropic's OAuth usage API (seven_day_sonnet). nil when unavailable.
    public let sevenDaySonnet: CapturedWindow?
    /// 7-day Opus-specific window. OAuth-only (seven_day_opus). nil when unavailable.
    public let sevenDayOpus: CapturedWindow?
    /// 7-day Fable-specific window. OAuth-only (legacy seven_day_fable key). nil when unavailable.
    public let sevenDayFable: CapturedWindow?
    /// Model-scoped 7-day window from OAuth `limits[]` `weekly_scoped` entry.
    /// The PRIMARY source for the per-model bar. Populated from `AppState.oauthSnapshot`.
    public let weeklyScopedWindow: CapturedWindow?
    /// Display name of the model for `weeklyScopedWindow` (e.g. "Fable", "Opus").
    public let weeklyScopedModel: String?
    // Public init so cross-module callers/tests can construct a snapshot directly.
    public init(accountName: String, sessionId: String, capturedAt: Date?, cwd: String?,
                modelId: String?, modelDisplayName: String?, effort: String?,
                contextUsedPercentage: Double?, totalInputTokens: Int?, totalCostUSD: Double?,
                fiveHour: CapturedWindow?, sevenDay: CapturedWindow?,
                sevenDaySonnet: CapturedWindow? = nil,
                sevenDayOpus: CapturedWindow? = nil,
                sevenDayFable: CapturedWindow? = nil,
                weeklyScopedWindow: CapturedWindow? = nil,
                weeklyScopedModel: String? = nil) {
        self.accountName = accountName
        self.sessionId = sessionId
        self.capturedAt = capturedAt
        self.cwd = cwd
        self.modelId = modelId
        self.modelDisplayName = modelDisplayName
        self.effort = effort
        self.contextUsedPercentage = contextUsedPercentage
        self.totalInputTokens = totalInputTokens
        self.totalCostUSD = totalCostUSD
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDaySonnet = sevenDaySonnet
        self.sevenDayOpus = sevenDayOpus
        self.sevenDayFable = sevenDayFable
        self.weeklyScopedWindow = weeklyScopedWindow
        self.weeklyScopedModel = weeklyScopedModel
    }
}

/// Reads `<configDir>/grove/usage/*.json` capture snapshots for one account.
/// Takes an explicit STRING configDir (never ~/.claude). Pure parse, defensive
/// against missing fields and corrupt files (skipped, never throws).
public struct UsageReader: Sendable {
    public init() {}

    public func read(configDir: String, accountName: String) -> [UsageSnapshot] {
        let usageDir = configDir + "/grove/usage"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: usageDir) else { return [] }

        var snapshots: [UsageSnapshot] = []
        for entry in entries where entry.hasSuffix(".json") {
            let path = usageDir + "/" + entry
            guard
                let data = fm.contents(atPath: path),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }   // corrupt files are skipped, never fatal

            // The wrapper wraps the render in a `{capturedAt, raw}` envelope; fall back
            // to the top-level object when `raw` is absent (forward-compat).
            let raw = (object["raw"] as? [String: Any]) ?? object
            guard let sessionId = raw["session_id"] as? String else { continue }

            let capturedAt = (object["capturedAt"] as? String).flatMap(gitISODate)
            let workspace = raw["workspace"] as? [String: Any]
            let cwd = (workspace?["current_dir"] as? String) ?? (raw["cwd"] as? String)
            let model = raw["model"] as? [String: Any]
            let modelId = model?["id"] as? String
            let modelDisplayName = model?["display_name"] as? String
            let effort = (raw["effort"] as? [String: Any])?["level"] as? String
            let contextWindow = raw["context_window"] as? [String: Any]
            let contextUsedPercentage = (contextWindow?["used_percentage"] as? NSNumber)?.doubleValue
            let totalInputTokens = (contextWindow?["total_input_tokens"] as? NSNumber)?.intValue
            let totalCostUSD = ((raw["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue

            let rateLimits = raw["rate_limits"] as? [String: Any]
            let fiveHour = Self.window(rateLimits?["five_hour"] as? [String: Any])
            let sevenDay = Self.window(rateLimits?["seven_day"] as? [String: Any])
            let sevenDaySonnet = Self.window(rateLimits?["seven_day_sonnet"] as? [String: Any])

            snapshots.append(UsageSnapshot(
                accountName: accountName,
                sessionId: sessionId,
                capturedAt: capturedAt,
                cwd: cwd,
                modelId: modelId,
                modelDisplayName: modelDisplayName,
                effort: effort,
                contextUsedPercentage: contextUsedPercentage,
                totalInputTokens: totalInputTokens,
                totalCostUSD: totalCostUSD,
                fiveHour: fiveHour,
                sevenDay: sevenDay,
                sevenDaySonnet: sevenDaySonnet))
        }
        return snapshots.sorted { $0.sessionId < $1.sessionId }
    }

    /// Parses one `rate_limits` window into a `CapturedWindow` (nil when absent).
    private static func window(_ object: [String: Any]?) -> CapturedWindow? {
        guard let object,
              let used = (object["used_percentage"] as? NSNumber)?.doubleValue
        else { return nil }
        return CapturedWindow(
            usedPercentage: used,
            resetsAt: normalizedResetsAt(object["resets_at"]))
    }

    /// Claude emits `resets_at` either as an ISO8601 string OR a Unix epoch number
    /// (seconds — or milliseconds for very large values). Normalize both to an
    /// ISO8601 string so RateLimitModel/LimitBar's `parseISODate` reads it uniformly;
    /// otherwise a numeric reset left the "Resets in" countdown blank.
    static func normalizedResetsAt(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let n = value as? NSNumber {
            var seconds = n.doubleValue
            if seconds > 1_000_000_000_000 { seconds /= 1000 }   // ms -> s
            guard seconds > 0 else { return nil }
            return resetsFormatter.string(from: Date(timeIntervalSince1970: seconds))
        }
        return nil
    }

    private static let resetsFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
