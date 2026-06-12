import Foundation

/// One window's rolled-up usage (today / this-month / last-7-days, or a session).
public struct UsageTotals: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var cost: Double
    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0,
                cacheWriteTokens: Int = 0, cost: Double = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheWriteTokens = cacheWriteTokens
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
    private struct ParsedRecord {
        let messageId: String
        let model: String
        let timestamp: Date?
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
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
                cacheWrite5mTokens: record.cacheWriteTokens, cacheWrite1hTokens: 0)
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
                + record.cacheReadTokens + record.cacheWriteTokens
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
        totals.cacheWriteTokens += record.cacheWriteTokens
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
                       input: Int, output: Int, cacheRead: Int, cacheWrite: Int)] = []

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
            let cacheWrite = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            pending.append((messageId, model, timestamp, input, output, cacheRead, cacheWrite))
        }

        let cwd = fileCwd ?? ""
        for p in pending {
            records.append(ParsedRecord(
                messageId: p.messageId, model: p.model, timestamp: p.timestamp,
                inputTokens: p.input, outputTokens: p.output,
                cacheReadTokens: p.cacheRead, cacheWriteTokens: p.cacheWrite,
                sessionId: sessionId, cwd: cwd))
        }
        return records
    }
}
