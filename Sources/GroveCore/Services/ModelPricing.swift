import Foundation

/// Embedded model -> price table (USD per million tokens) and the cache-tier
/// multipliers. Zero external deps, ONE place to update prices (spec §C.2).
/// Cache rules: cache READ = 0.1x input; 5-minute cache WRITE = 1.25x input;
/// 1-hour cache WRITE = 2x input (the named multiplier constants below).
public enum ModelPricing {
    public struct Price: Sendable, Equatable {
        public let inputPerMTok: Double
        public let outputPerMTok: Double
        public init(inputPerMTok: Double, outputPerMTok: Double) {
            self.inputPerMTok = inputPerMTok
            self.outputPerMTok = outputPerMTok
        }
    }

    public static let cacheReadMultiplier = 0.1
    public static let cacheWrite5mMultiplier = 1.25
    public static let cacheWrite1hMultiplier = 2.0

    /// REAL embedded rates (USD per 1,000,000 tokens). Keys are the exact
    /// `message.model` strings Claude Code records. Cache prices are DERIVED from
    /// `inputPerMTok` via the multiplier constants above — never stored separately.
    /// This literal is the only thing to edit when prices move. NOT a placeholder:
    /// the suite asserts these exact rows.
    public static let table: [String: Price] = [
        "claude-fable-5":    Price(inputPerMTok: 10, outputPerMTok: 50),
        "claude-opus-4-8":   Price(inputPerMTok: 5,  outputPerMTok: 25),
        "claude-opus-4-7":   Price(inputPerMTok: 5,  outputPerMTok: 25),
        "claude-opus-4-6":   Price(inputPerMTok: 5,  outputPerMTok: 25),
        "claude-sonnet-4-6": Price(inputPerMTok: 3,  outputPerMTok: 15),
        "claude-haiku-4-5":  Price(inputPerMTok: 1,  outputPerMTok: 5),
    ]

    public static var knownModels: [String] { Array(table.keys).sorted() }

    /// Price for a model id, NORMALIZING before lookup so transcript variants
    /// resolve to a table row:
    ///   1. exact id (`claude-opus-4-8`);
    ///   2. strip a trailing `[1m]` 1M-context suffix (`claude-opus-4-8[1m]` ->
    ///      `claude-opus-4-8`);
    ///   3. strip a trailing `-YYYYMMDD` date suffix (`claude-haiku-4-5-20251001`
    ///      -> `claude-haiku-4-5`).
    /// Returns nil for unknown ids and `<synthetic>` (which has no table row).
    public static func price(for model: String) -> Price? {
        if let p = table[model] { return p }
        var id = model
        if id.hasSuffix("[1m]") { id = String(id.dropLast(4)) }
        if let p = table[id] { return p }
        // Strip a trailing "-YYYYMMDD" date suffix if present.
        if let dash = id.lastIndex(of: "-") {
            let suffix = id[id.index(after: dash)...]
            if suffix.count == 8, suffix.allSatisfy(\.isNumber) {
                let base = String(id[..<dash])
                if let p = table[base] { return p }
            }
        }
        return nil
    }

    /// USD cost for one record's token counts. Unknown / `<synthetic>` model -> 0
    /// (surfaced separately by UsageAnalytics — DEGRADES, never crashes).
    /// cacheWrite1h defaults 0 (rare).
    public static func cost(model: String, inputTokens: Int, outputTokens: Int,
                            cacheReadTokens: Int, cacheWrite5mTokens: Int,
                            cacheWrite1hTokens: Int) -> Double {
        guard let p = price(for: model) else { return 0 }
        let m = 1.0 / 1_000_000.0
        return p.inputPerMTok * Double(inputTokens) * m
            + p.outputPerMTok * Double(outputTokens) * m
            + p.inputPerMTok * cacheReadMultiplier * Double(cacheReadTokens) * m
            + p.inputPerMTok * cacheWrite5mMultiplier * Double(cacheWrite5mTokens) * m
            + p.inputPerMTok * cacheWrite1hMultiplier * Double(cacheWrite1hTokens) * m
    }
}
