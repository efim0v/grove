import Foundation

/// One window's captured limit (from statusline rate_limits.{five_hour,seven_day}).
public struct CapturedWindow: Sendable, Equatable {
    public let usedPercentage: Double
    public let resetsAt: String?   // raw ISO8601; RateLimitModel parses it
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
                sevenDay: sevenDay))
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
            resetsAt: object["resets_at"] as? String)
    }
}
