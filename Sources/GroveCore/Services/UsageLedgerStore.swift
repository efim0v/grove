import Foundation

// MARK: - Snapshot-delta usage ledger
//
// The Daily Usage chart can't rely on transcript JSONL alone: long, context-continued,
// workflow-heavy sessions stop flushing per-message usage records, so recent days read empty.
// This ledger instead tracks the CUMULATIVE per-session cost from Grove's statusline snapshots
// (`UsageSnapshot.totalCostUSD`, the only monotonic cumulative metric available) and records the
// per-day DELTA. It is forward-accurate: a session's FIRST observation only sets a baseline
// (delta 0) so pre-tracking spend is never dumped onto day one; every subsequent refresh adds the
// increase since the last observation, attributed to the snapshot's captured day. One file per
// account under `<Application Support>/Grove/usageledger`.

/// The last cumulative cost observed for one session — the high-water mark the next refresh
/// diffs against to produce a per-day delta.
public struct SessionCostCursor: Codable, Sendable, Equatable {
    public var lastCumulativeCostUSD: Double
    public var lastObservedAt: Date
    public init(lastCumulativeCostUSD: Double, lastObservedAt: Date) {
        self.lastCumulativeCostUSD = lastCumulativeCostUSD
        self.lastObservedAt = lastObservedAt
    }
}

/// One day's accumulated cost delta. `day` is UTC start-of-day, byte-for-byte matching
/// `UsageAnalytics`'s day axis so a `[Date: Double]` lookup against the chart's day keys is exact.
public struct LedgerDay: Codable, Sendable, Equatable {
    public let day: Date
    public var costUSD: Double
    public init(day: Date, costUSD: Double) {
        self.day = day
        self.costUSD = costUSD
    }
}

/// One account's ledger: a per-session cursor map + the accumulated per-day cost, sorted oldest
/// first. `version` lets a future migration distinguish formats.
public struct UsageCostLedger: Codable, Sendable, Equatable {
    public var cursors: [String: SessionCostCursor]
    public var days: [LedgerDay]
    public var version: Int

    public init(cursors: [String: SessionCostCursor] = [:], days: [LedgerDay] = [], version: Int = 1) {
        self.cursors = cursors
        self.days = days
        self.version = version
    }

    private enum CodingKeys: String, CodingKey { case cursors, days, version }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursors = try c.decodeIfPresent([String: SessionCostCursor].self, forKey: .cursors) ?? [:]
        days = try c.decodeIfPresent([LedgerDay].self, forKey: .days) ?? []
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }

    /// UTC gregorian calendar — same construction as `UsageAnalytics`, so day keys align exactly.
    public static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// The accumulated cost delta for a UTC start-of-day, or 0 if that day has no tracked delta.
    public func cost(on day: Date) -> Double {
        days.first { $0.day == day }?.costUSD ?? 0
    }

    /// Per-day cost for ONLY the days the ledger has recorded a delta for. Membership of a day in
    /// this map is the "Grove tracked this day" signal the chart merge keys off — pre-tracking
    /// days are absent (so they keep transcript cost), tracked-but-zero days are present at 0.
    public var costByDay: [Date: Double] {
        Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0.costUSD) })
    }

    /// Folds a fresh batch of statusline snapshots into `ledger`, returning whether anything
    /// changed (so the caller persists only on a real change). Per session: a FIRST observation
    /// sets a baseline cursor and contributes 0 (no pre-tracking backfill); a later observation
    /// adds `max(0, cumulative − cursor)` to the snapshot's captured day and advances the cursor
    /// upward only (a decrease = session reset / stale render / compaction is ignored, never a
    /// negative day delta). Cursors + days older than `retention` are pruned to bound the file.
    /// PURE (injected `now`); excludes the synthetic OAuth snapshot (sessionId "oauth", nil cost).
    @discardableResult
    public static func fold(into ledger: inout UsageCostLedger, snapshots: [UsageSnapshot],
                            now: Date, retention: TimeInterval = 60 * 86_400) -> Bool {
        let cal = utcCalendar
        var cursors = ledger.cursors
        var dayCost: [Date: Double] = Dictionary(
            uniqueKeysWithValues: ledger.days.map { ($0.day, $0.costUSD) })

        // One snapshot per session normally, but group + order by capturedAt defensively so the
        // cursor ends on the latest observation regardless of input order.
        let bySession = Dictionary(grouping: snapshots, by: \.sessionId)
        for (sessionId, group) in bySession {
            guard sessionId != "oauth" else { continue }   // synthetic limit snapshot: nil cost
            let ordered = group
                .filter { $0.totalCostUSD != nil }
                .sorted { ($0.capturedAt ?? .distantPast) < ($1.capturedAt ?? .distantPast) }
            for snap in ordered {
                guard let cumulative = snap.totalCostUSD, cumulative >= 0 else { continue }
                let capturedAt = snap.capturedAt
                if let cursor = cursors[sessionId] {
                    let delta = cumulative - cursor.lastCumulativeCostUSD
                    // A delta with no captured day can't be placed on the axis: drop the cost but
                    // still advance the cursor below, so it's never re-counted by a later snapshot.
                    if delta > 0, let capturedAt {
                        dayCost[cal.startOfDay(for: capturedAt), default: 0] += delta
                    }
                    // Advance lastObservedAt on EVERY observation (the statusline rewrites the
                    // file with a fresh capturedAt even when cost is flat), so a long-running but
                    // cost-flat session isn't pruned out and then mis-re-seeded; the cumulative
                    // stays a monotonic high-water mark (a decrease is still ignored).
                    cursors[sessionId] = SessionCostCursor(
                        lastCumulativeCostUSD: max(cumulative, cursor.lastCumulativeCostUSD),
                        lastObservedAt: max(capturedAt ?? cursor.lastObservedAt, cursor.lastObservedAt))
                } else {
                    // First observation: baseline only, no delta.
                    cursors[sessionId] = SessionCostCursor(
                        lastCumulativeCostUSD: cumulative,
                        lastObservedAt: capturedAt ?? now)
                }
            }
        }

        let cutoff = now.addingTimeInterval(-retention)
        let prunedCursors = cursors.filter { $0.value.lastObservedAt >= cutoff }
        let dayCutoff = cal.startOfDay(for: cutoff)
        let prunedDays = dayCost
            .filter { $0.key >= dayCutoff }
            .map { LedgerDay(day: $0.key, costUSD: $0.value) }
            .sorted { $0.day < $1.day }

        let updated = UsageCostLedger(cursors: prunedCursors, days: prunedDays, version: ledger.version)
        guard updated != ledger else { return false }
        ledger = updated
        return true
    }
}

/// Per-account persistence for `UsageCostLedger`, mirroring `CodeStatsStore`: one `<account>.json`
/// per account under `dir`, atomic temp-write+rename, missing/corrupt → empty (never throws on
/// read). Value type holding a URL, so it crosses the off-main refresh boundary safely.
public struct UsageCostLedgerStore: Sendable {
    private let dir: URL
    public init(dir: URL) { self.dir = dir }

    /// Account names are user-chosen and may contain path-hostile characters; percent-encode all
    /// non-alphanumerics so the filename is unique + filesystem-safe (reversible, collision-free).
    private func url(for account: String) -> URL {
        let safe = account.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? account
        return dir.appendingPathComponent("\(safe).json")
    }

    public func load(account: String) -> UsageCostLedger {
        guard let data = try? Data(contentsOf: url(for: account)),
              let ledger = try? JSONDecoder().decode(UsageCostLedger.self, from: data)
        else { return UsageCostLedger() }
        return ledger
    }

    public func delete(account: String) {
        try? FileManager.default.removeItem(at: url(for: account))
    }

    public func save(account: String, ledger: UsageCostLedger) throws {
        let fm = FileManager.default
        let url = url(for: account)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(ledger)
            let tmp = dir.appendingPathComponent("\(url.lastPathComponent).tmp-\(UUID().uuidString)")
            try data.write(to: tmp, options: [])
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            throw GroveError.io("failed to save usage ledger to \(url.path): \(error.localizedDescription)")
        }
    }
}

/// Serializes ledger persistence so two concurrent refreshes can't write the file out of order.
/// Each save carries a per-account monotonic generation (stamped on the serialized main actor);
/// a save whose generation is older than the last written for that account is SKIPPED, so the
/// most-complete ledger always wins on disk. The in-memory ledger remains the source of truth,
/// so a skipped/stale write self-corrects on the next fold.
public actor UsageLedgerWriter {
    private var written: [String: Int] = [:]
    public init() {}
    public func save(account: String, ledger: UsageCostLedger, generation: Int,
                     store: UsageCostLedgerStore) {
        if let prev = written[account], generation < prev { return }
        written[account] = generation
        try? store.save(account: account, ledger: ledger)
    }
}
