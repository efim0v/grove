import XCTest
@testable import GroveCore

final class UsageAnalyticsTests: XCTestCase {
    private let fm = FileManager.default
    private var configDir: URL!     // stands in for a CLAUDE_CONFIG_DIR (NEVER real)
    private let analytics = UsageAnalytics()
    // A fixed instant so today/month bucketing is deterministic (UTC).
    private let now = Date(timeIntervalSince1970: 1_750_000_000)   // 2025-06-15T...Z

    override func setUpWithError() throws {
        configDir = try Fixture.tempDir("usage-analytics")
    }

    /// Writes a transcript line set under projects/<mangled>/<id>.jsonl.
    private func writeTranscript(cwd: String, id: String, lines: [String]) throws {
        let dir = configDir.appendingPathComponent("projects")
            .appendingPathComponent(ClaudeService.mangle(cwd))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n")
            .write(to: dir.appendingPathComponent("\(id).jsonl"),
                   atomically: true, encoding: .utf8)
    }

    /// One assistant record with a usage block and an explicit timestamp.
    private func assistant(id: String, model: String, inTok: Int, outTok: Int,
                           cacheRead: Int = 0, cacheWrite5m: Int = 0,
                           ts: String) -> String {
        """
        {"type":"assistant","timestamp":"\(ts)","message":{"id":"\(id)","model":"\(model)",
        "usage":{"input_tokens":\(inTok),"output_tokens":\(outTok),
        "cache_read_input_tokens":\(cacheRead),
        "cache_creation_input_tokens":\(cacheWrite5m)}}}
        """.replacingOccurrences(of: "\n", with: "")
    }

    // MARK: - price math, table lookup/normalization, and $0 degradation

    /// Cost math asserted DIRECTLY against an explicit Price — does NOT depend on
    /// the table being populated (no `knownModels.first!` trap). Exercises input,
    /// output, cache-read (0.1x), cache-5m-write (1.25x) and cache-1h-write (2x).
    func testCostMathUsesInputOutputAndCacheMultipliers() {
        let price = ModelPricing.Price(inputPerMTok: 5, outputPerMTok: 25)
        // 1000 input, 1000 output, 1000 cache-read, 1000 5m-write, 1000 1h-write.
        let cost = ModelPricing.cost(model: "claude-opus-4-8",
                                     inputTokens: 1000, outputTokens: 1000,
                                     cacheReadTokens: 1000, cacheWrite5mTokens: 1000,
                                     cacheWrite1hTokens: 1000)
        let m = 0.001   // 1000 tokens / 1_000_000
        let expected = price.inputPerMTok * m
            + price.outputPerMTok * m
            + price.inputPerMTok * ModelPricing.cacheReadMultiplier * m
            + price.inputPerMTok * ModelPricing.cacheWrite5mMultiplier * m
            + price.inputPerMTok * ModelPricing.cacheWrite1hMultiplier * m
        XCTAssertEqual(cost, expected, accuracy: 1e-9)
        // Sanity: claude-opus-4-8 IS the 5/25 row, so the model-keyed cost matches.
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-8"), price)
    }

    /// price(for:) returns the right rows AND normalizes [1m] / -YYYYMMDD suffixes.
    func testPriceLookupNormalizesModelIdVariants() {
        let opus = ModelPricing.Price(inputPerMTok: 5, outputPerMTok: 25)
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-8"), opus)
        // 1M-context suffix strips to the base row.
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-8[1m]"), opus)
        // Dated id strips its -YYYYMMDD suffix to the base row.
        XCTAssertEqual(ModelPricing.price(for: "claude-haiku-4-5-20251001"),
                       ModelPricing.Price(inputPerMTok: 1, outputPerMTok: 5))
        // Unknown / synthetic -> nil (cost degrades to $0).
        XCTAssertNil(ModelPricing.price(for: "<synthetic>"))
        XCTAssertNil(ModelPricing.price(for: "some-future-model"))
    }

    func testUnknownModelCostsZeroAndIsSurfacedSeparately() throws {
        try writeTranscript(cwd: "/ws/x", id: "u", lines: [
            assistant(id: "m1", model: "<synthetic>", inTok: 100, outTok: 100,
                      ts: "2025-06-15T10:00:00.000Z"),
            assistant(id: "m2", model: "some-future-model", inTok: 100, outTok: 100,
                      ts: "2025-06-15T10:01:00.000Z"),
        ])
        let acc = analytics.account(configDir: configDir.path, accountName: "a", now: now)
        XCTAssertEqual(acc.unpricedCost, 0)
        XCTAssertEqual(Set(acc.unpricedModels), ["<synthetic>", "some-future-model"])
        // Unknown models contribute tokens but zero priced cost (degrades, no crash).
        XCTAssertEqual(acc.today.cost, 0, accuracy: 1e-9)
        XCTAssertEqual(acc.today.inputTokens, 200)
    }

    // MARK: - dedup by message.id; skip records without usage

    func testDedupByMessageIdAndSkipRecordsWithoutUsage() throws {
        let model = "claude-opus-4-8"   // a concrete table row (no `knownModels.first!`)
        try writeTranscript(cwd: "/ws/x", id: "u", lines: [
            assistant(id: "dup", model: model, inTok: 100, outTok: 50,
                      ts: "2025-06-15T10:00:00.000Z"),
            // exact same message.id again (streaming partial re-log) -> counted ONCE.
            assistant(id: "dup", model: model, inTok: 100, outTok: 50,
                      ts: "2025-06-15T10:00:01.000Z"),
            // a record with NO usage block -> skipped (not zero-filled).
            #"{"type":"user","timestamp":"2025-06-15T10:00:02.000Z","message":{"id":"u1","content":"hi"}}"#,
        ])
        let acc = analytics.account(configDir: configDir.path, accountName: "a", now: now)
        XCTAssertEqual(acc.today.inputTokens, 100, "dup message counted once")
        XCTAssertEqual(acc.today.outputTokens, 50)
    }

    // MARK: - today / month / 7d bucketing from injected `now`

    func testTodayMonthSevenDayBucketsUseTimestampsAgainstInjectedNow() throws {
        let model = "claude-opus-4-8"   // a concrete table row (no `knownModels.first!`)
        try writeTranscript(cwd: "/ws/x", id: "u", lines: [
            assistant(id: "today", model: model, inTok: 10, outTok: 0,
                      ts: "2025-06-15T09:00:00.000Z"),          // same UTC day as now
            assistant(id: "thisweek", model: model, inTok: 20, outTok: 0,
                      ts: "2025-06-12T09:00:00.000Z"),          // 3 days ago
            assistant(id: "thismonth", model: model, inTok: 40, outTok: 0,
                      ts: "2025-06-02T09:00:00.000Z"),          // same month, >7d
            assistant(id: "old", model: model, inTok: 80, outTok: 0,
                      ts: "2025-04-01T09:00:00.000Z"),          // outside all windows
        ])
        let acc = analytics.account(configDir: configDir.path, accountName: "a", now: now)
        XCTAssertEqual(acc.today.inputTokens, 10)
        XCTAssertEqual(acc.last7d.inputTokens, 30)              // today + thisweek
        XCTAssertEqual(acc.thisMonth.inputTokens, 70)           // today + thisweek + thismonth
    }

    // MARK: - per-session output

    func testPerSessionTotalsAndModelBreakdown() throws {
        let m = "claude-opus-4-8"   // a concrete table row (no `knownModels.first!`)
        try writeTranscript(cwd: "/ws/x", id: "sess-1", lines: [
            assistant(id: "a", model: m, inTok: 100, outTok: 100,
                      ts: "2025-06-15T10:00:00.000Z"),
            assistant(id: "b", model: m, inTok: 50, outTok: 50,
                      ts: "2025-06-15T10:05:00.000Z"),
        ])
        let acc = analytics.account(configDir: configDir.path, accountName: "a", now: now)
        let s = try XCTUnwrap(acc.sessions["sess-1"])
        XCTAssertEqual(s.inputTokens, 150)
        XCTAssertEqual(s.outputTokens, 150)
        XCTAssertEqual(s.modelBreakdown[m], 300)   // total tokens for that model
        XCTAssertGreaterThan(s.cost, 0)
    }

    // MARK: - prefer pre-computed costUSD from lastModelUsage

    func testPrefersPrecomputedCostFromLastModelUsageWhenPresent() throws {
        // .claude.json projects[cwd].lastModelUsage carries an authoritative costUSD.
        let m = "claude-opus-4-8"   // a concrete table row (no `knownModels.first!`)
        try writeTranscript(cwd: "/ws/x", id: "sess-1", lines: [
            assistant(id: "a", model: m, inTok: 1000, outTok: 1000,
                      ts: "2025-06-15T10:00:00.000Z"),
        ])
        let claudeJSON = """
        {"projects":{"/ws/x":{"lastModelUsage":{"\(m)":
        {"inputTokens":1000,"outputTokens":1000,"cacheReadInputTokens":0,
        "cacheCreationInputTokens":0,"costUSD":4.2}}}}}
        """
        try claudeJSON.write(to: configDir.appendingPathComponent(".claude.json"),
                             atomically: true, encoding: .utf8)
        let acc = analytics.account(configDir: configDir.path, accountName: "a",
                                    claudeJSONPath: configDir.appendingPathComponent(".claude.json").path,
                                    now: now)
        // The model's account-wide cost prefers the authoritative 4.2 over the computed value.
        // (costByModel is [String: Double]; unwrap the optional subscript for the
        // accuracy overload, which requires a non-optional FloatingPoint.)
        XCTAssertEqual(try XCTUnwrap(acc.costByModel[m]), 4.2, accuracy: 1e-9)
    }

    // MARK: - mtime cache: a re-read with an unchanged file does not re-parse

    func testMtimeCacheSkipsReparseWhenFileUnchanged() throws {
        let m = "claude-opus-4-8"   // a concrete table row (no `knownModels.first!`)
        try writeTranscript(cwd: "/ws/x", id: "u", lines: [
            assistant(id: "a", model: m, inTok: 10, outTok: 0, ts: "2025-06-15T10:00:00.000Z"),
        ])
        let first = analytics.account(configDir: configDir.path, accountName: "a", now: now)
        let second = analytics.account(configDir: configDir.path, accountName: "a", now: now)
        XCTAssertEqual(first.today.inputTokens, second.today.inputTokens)
        XCTAssertGreaterThan(analytics.cacheHitCount, 0, "second pass hit the mtime cache")
    }
}
