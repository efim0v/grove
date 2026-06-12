import Foundation

/// One window's rolled-up usage (today / this-month / last-7-days, or a session).
///
/// Cache writes are kept as two SEPARATE tiers — the Anthropic API prices a
/// 5-minute ephemeral write at 1.25x input and a 1-hour write at 2x input
/// (spec §C.2, "the #1 source of wrong numbers"), so a single conflated field
/// can't be costed or audited correctly. `cacheWriteTokens` is the sum of both,
/// kept only for callers that want the total. See `UsageAnalytics.parseFile`
/// for how the two tiers are extracted from the transcript.
public struct UsageTotals: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    /// 5-minute ephemeral cache writes (1.25x input).
    public var cacheWrite5mTokens: Int
    /// 1-hour ephemeral cache writes (2x input).
    public var cacheWrite1hTokens: Int
    public var cost: Double
    /// Total cache-write tokens across both TTL tiers (5m + 1h).
    public var cacheWriteTokens: Int { cacheWrite5mTokens + cacheWrite1hTokens }
    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0,
                cacheWrite5mTokens: Int = 0, cacheWrite1hTokens: Int = 0, cost: Double = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
        self.cost = cost
    }
}

/// Per-session rollup (for the session cards, spec §C.5).
public struct SessionUsage: Sendable, Equatable {
    public let sessionId: String
    public let cwd: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cost: Double
    /// total tokens per model id (for the breakdown %).
    public var modelBreakdown: [String: Int]
    public var lastActivity: Date?
    // Public init so cross-module callers (the snapshot fixture, Task 12) can
    // construct a session rollup directly.
    public init(sessionId: String, cwd: String, inputTokens: Int = 0, outputTokens: Int = 0,
                cost: Double = 0, modelBreakdown: [String: Int] = [:], lastActivity: Date? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cost = cost
        self.modelBreakdown = modelBreakdown
        self.lastActivity = lastActivity
    }
}

/// Account-wide analytics across one CLAUDE_CONFIG_DIR's transcripts.
public struct AccountUsageAnalytics: Sendable, Equatable {
    public let accountName: String
    public var today: UsageTotals
    public var thisMonth: UsageTotals
    public var last7d: UsageTotals
    public var sessions: [String: SessionUsage]   // keyed by sessionId
    /// account-wide USD per model (prefers lastModelUsage.costUSD when present).
    public var costByModel: [String: Double]
    /// per-workspace (cwd) aggregate tokens, for richer workspace rows (Task 11).
    public var byCwd: [String: UsageTotals]
    /// models seen with no price (e.g. "<synthetic>") -> surfaced, never crash.
    public var unpricedModels: [String]
    public var unpricedCost: Double   // always 0 by definition; kept explicit for the UI

    public init(accountName: String, today: UsageTotals, thisMonth: UsageTotals,
                last7d: UsageTotals, sessions: [String: SessionUsage],
                costByModel: [String: Double], byCwd: [String: UsageTotals],
                unpricedModels: [String], unpricedCost: Double) {
        self.accountName = accountName
        self.today = today
        self.thisMonth = thisMonth
        self.last7d = last7d
        self.sessions = sessions
        self.costByModel = costByModel
        self.byCwd = byCwd
        self.unpricedModels = unpricedModels
        self.unpricedCost = unpricedCost
    }
}

/// Sums per-message usage across an account's transcripts against ModelPricing.
/// mtime-keyed parse cache like ClaudeService.sessions: a jsonl is re-summed only
/// when its mtime changes. Takes explicit STRING dir paths (never ~/.claude) and an
/// injected `now` for the today/month/7d windows (no Date() in the math).
public final class UsageAnalytics {
    public init() {}

    /// Test/diagnostic: increments on every mtime-cache hit.
    public private(set) var cacheHitCount = 0

    /// One assistant-record's parsed usage (a single deduped message).
    ///
    /// Cache writes are split into the two API-priced TTL tiers (5-minute and
    /// 1-hour) rather than one conflated field, so the cost function gets the
    /// right multiplier for each (spec §C.2). See `parseFile` for how the tiers
    /// are read from the transcript.
    private struct ParsedRecord {
        let messageId: String
        let model: String
        let timestamp: Date?
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWrite5mTokens: Int
        let cacheWrite1hTokens: Int
        let sessionId: String
        let cwd: String
    }

    private let cacheLock = NSLock()
    private var parseCache: [String: (mtime: Date, records: [ParsedRecord])] = [:]

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// Account-wide analytics. `claudeJSONPath` (optional) points at the account's
    /// .claude.json whose projects[cwd].lastModelUsage.costUSD is preferred for
    /// costByModel when present. `now` defines the windows.
    public func account(configDir: String, accountName: String,
                        claudeJSONPath: String? = nil,
                        now: Date) -> AccountUsageAnalytics {
        let records = parseAllRecords(configDir: configDir)

        // Dedup by message.id (first occurrence wins).
        var seen = Set<String>()
        var deduped: [ParsedRecord] = []
        for record in records where seen.insert(record.messageId).inserted {
            deduped.append(record)
        }

        var today = UsageTotals()
        var thisMonth = UsageTotals()
        var last7d = UsageTotals()
        var sessions: [String: SessionUsage] = [:]
        var byCwd: [String: UsageTotals] = [:]
        var costByModel: [String: Double] = [:]
        var unpricedSet = Set<String>()

        let cal = UsageAnalytics.utcCalendar
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86_400)

        for record in deduped {
            let recordCost = ModelPricing.cost(
                model: record.model,
                inputTokens: record.inputTokens, outputTokens: record.outputTokens,
                cacheReadTokens: record.cacheReadTokens,
                cacheWrite5mTokens: record.cacheWrite5mTokens,
                cacheWrite1hTokens: record.cacheWrite1hTokens)
            if ModelPricing.price(for: record.model) == nil {
                unpricedSet.insert(record.model)
            }

            // Window bucketing by UTC against the injected `now`.
            if let ts = record.timestamp {
                if cal.isDate(ts, inSameDayAs: now) {
                    add(&today, record, cost: recordCost)
                }
                if ts >= sevenDaysAgo && ts <= now {
                    add(&last7d, record, cost: recordCost)
                }
                if cal.isDate(ts, equalTo: now, toGranularity: .month) {
                    add(&thisMonth, record, cost: recordCost)
                }
            }

            // Per-session rollup.
            var session = sessions[record.sessionId] ?? SessionUsage(
                sessionId: record.sessionId, cwd: record.cwd,
                inputTokens: 0, outputTokens: 0, cost: 0,
                modelBreakdown: [:], lastActivity: nil)
            session.inputTokens += record.inputTokens
            session.outputTokens += record.outputTokens
            session.cost += recordCost
            let modelTokens = record.inputTokens + record.outputTokens
                + record.cacheReadTokens
                + record.cacheWrite5mTokens + record.cacheWrite1hTokens
            session.modelBreakdown[record.model, default: 0] += modelTokens
            if let ts = record.timestamp {
                session.lastActivity = max(session.lastActivity ?? ts, ts)
            }
            sessions[record.sessionId] = session

            // Per-cwd rollup.
            var cwdTotals = byCwd[record.cwd] ?? UsageTotals()
            add(&cwdTotals, record, cost: recordCost)
            byCwd[record.cwd] = cwdTotals

            // Computed per-model cost (may be overridden below).
            costByModel[record.model, default: 0] += recordCost
        }

        // Prefer authoritative lastModelUsage.costUSD when present.
        if let claudeJSONPath,
           let data = FileManager.default.contents(atPath: claudeJSONPath),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let projects = object["projects"] as? [String: Any] {
            var authoritative: [String: Double] = [:]
            for (_, projectValue) in projects {
                guard let project = projectValue as? [String: Any],
                      let lastModelUsage = project["lastModelUsage"] as? [String: Any]
                else { continue }
                for (model, usageValue) in lastModelUsage {
                    guard let usage = usageValue as? [String: Any],
                          let costUSD = (usage["costUSD"] as? NSNumber)?.doubleValue
                    else { continue }
                    authoritative[model, default: 0] += costUSD
                }
            }
            for (model, cost) in authoritative {
                costByModel[model] = cost   // OVERRIDE: prefer pre-computed.
            }
        }

        return AccountUsageAnalytics(
            accountName: accountName,
            today: today, thisMonth: thisMonth, last7d: last7d,
            sessions: sessions, costByModel: costByModel, byCwd: byCwd,
            unpricedModels: unpricedSet.sorted(), unpricedCost: 0)
    }

    private func add(_ totals: inout UsageTotals, _ record: ParsedRecord, cost: Double) {
        totals.inputTokens += record.inputTokens
        totals.outputTokens += record.outputTokens
        totals.cacheReadTokens += record.cacheReadTokens
        totals.cacheWrite5mTokens += record.cacheWrite5mTokens
        totals.cacheWrite1hTokens += record.cacheWrite1hTokens
        totals.cost += cost
    }

    /// All parsed usage records across every transcript file under
    /// `<configDir>/projects/<mangled>/*.jsonl` (regular files only).
    private func parseAllRecords(configDir: String) -> [ParsedRecord] {
        let fm = FileManager.default
        let projectsDir = configDir + "/projects"
        guard let mangledDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }
        var all: [ParsedRecord] = []
        for mangled in mangledDirs {
            let dir = projectsDir + "/" + mangled
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let path = dir + "/" + name
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { continue }
                guard
                    let attributes = try? fm.attributesOfItem(atPath: path),
                    let mtime = attributes[.modificationDate] as? Date
                else { continue }
                let sessionId = (name as NSString).deletingPathExtension
                all.append(contentsOf: cachedParse(path: path, mtime: mtime, sessionId: sessionId))
            }
        }
        return all
    }

    private func cachedParse(path: String, mtime: Date, sessionId: String) -> [ParsedRecord] {
        cacheLock.lock()
        if let entry = parseCache[path], entry.mtime == mtime {
            let records = entry.records
            cacheHitCount += 1
            cacheLock.unlock()
            return records
        }
        cacheLock.unlock()
        let records = UsageAnalytics.parseFile(path: path, sessionId: sessionId)
        cacheLock.lock()
        parseCache[path] = (mtime: mtime, records: records)
        cacheLock.unlock()
        return records
    }

    private static func parseFile(path: String, sessionId: String) -> [ParsedRecord] {
        guard
            let data = FileManager.default.contents(atPath: path),
            let text = String(data: data, encoding: .utf8)
        else { return [] }

        // The cwd is the first record carrying a "cwd" key (mangling is lossy).
        var fileCwd: String?
        var records: [ParsedRecord] = []
        var pending: [(messageId: String, model: String, timestamp: Date?,
                       input: Int, output: Int, cacheRead: Int,
                       cacheWrite5m: Int, cacheWrite1h: Int)] = []

        for line in text.split(whereSeparator: \.isNewline) {
            guard
                let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8)))
                    as? [String: Any]
            else { continue }
            if fileCwd == nil, let recordCwd = object["cwd"] as? String {
                fileCwd = recordCwd
            }
            guard
                let message = object["message"] as? [String: Any],
                let usage = message["usage"] as? [String: Any]
            else { continue }   // keep only records WITH a usage block (not zero-filled)
            guard let messageId = message["id"] as? String,
                  let model = message["model"] as? String
            else { continue }
            let timestamp = (object["timestamp"] as? String).flatMap(gitISODate)
            let input = (usage["input_tokens"] as? Int) ?? 0
            let output = (usage["output_tokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
            let (cacheWrite5m, cacheWrite1h) = Self.cacheWriteTiers(usage: usage)
            pending.append((messageId, model, timestamp, input, output,
                            cacheRead, cacheWrite5m, cacheWrite1h))
        }

        let cwd = fileCwd ?? ""
        for p in pending {
            records.append(ParsedRecord(
                messageId: p.messageId, model: p.model, timestamp: p.timestamp,
                inputTokens: p.input, outputTokens: p.output,
                cacheReadTokens: p.cacheRead,
                cacheWrite5mTokens: p.cacheWrite5m, cacheWrite1hTokens: p.cacheWrite1h,
                sessionId: sessionId, cwd: cwd))
        }
        return records
    }

    /// Splits a `usage` block's cache-creation tokens into the two TTL tiers
    /// the Anthropic API prices differently (5-minute 1.25x vs 1-hour 2x —
    /// spec §C.2, "the #1 source of wrong numbers").
    ///
    /// The API breaks the tiers out under a nested `cache_creation` object
    /// (`ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`); the flat
    /// `cache_creation_input_tokens` is their sum. When the nested object is
    /// present we use it directly — no assumption. When it is ABSENT (the
    /// common case for transcripts that record only the flat total, and the
    /// default for `cache_control: {type: "ephemeral"}` whose default TTL is
    /// 5 minutes), we attribute the flat total to the 5-minute tier. This is a
    /// documented, conservative fallback (the 5m tier is the cheaper of the two,
    /// so it never over-states cost) rather than a unilateral claim that 1-hour
    /// writes never occur — they are read whenever the API records them.
    private static func cacheWriteTiers(usage: [String: Any]) -> (write5m: Int, write1h: Int) {
        if let breakdown = usage["cache_creation"] as? [String: Any] {
            let write5m = (breakdown["ephemeral_5m_input_tokens"] as? Int) ?? 0
            let write1h = (breakdown["ephemeral_1h_input_tokens"] as? Int) ?? 0
            // If the nested object is present but empty, fall through to the flat total.
            if write5m != 0 || write1h != 0 { return (write5m, write1h) }
        }
        let flat = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        return (flat, 0)   // flat total -> 5-minute tier (default TTL); no 1h assumed absent
    }
}
