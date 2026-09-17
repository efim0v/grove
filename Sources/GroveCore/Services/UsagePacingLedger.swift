import Foundation

/// What one process knows about the endpoint's bucket for a config dir — the last 200,
/// the bucket level it left behind, any 429 window still open — and the reading that
/// last 200 produced. Written after every request, read before every decision, so two
/// apps polling `api/oauth/usage` with the same token (Grove's panel and Brow) draw on
/// ONE picture of the bucket instead of each believing it owns the refill.
public struct UsagePacingRecord: Codable, Sendable, Equatable {
    public var lastSuccessAt: Date
    public var level: Double
    public var levelAt: Date
    public var backoffUntil: Date?
    public var attempts: Int
    public var reading: OAuthUsage?

    public init(lastSuccessAt: Date, level: Double, levelAt: Date,
                backoffUntil: Date? = nil, attempts: Int = 0, reading: OAuthUsage? = nil) {
        self.lastSuccessAt = lastSuccessAt
        self.level = level
        self.levelAt = levelAt
        self.backoffUntil = backoffUntil
        self.attempts = attempts
        self.reading = reading
    }
}

/// Keyed by config dir. `store` is a read-modify-write of one key; a lost update
/// between two processes costs at most one extra request, never a wrong reading.
public protocol UsagePacingLedger: Sendable {
    func load() -> [String: UsagePacingRecord]
    func store(_ record: UsagePacingRecord, for key: String)
}

/// `<directory>/oauth-usage-ledger.json`. Lives under Grove's support folder because
/// GroveCore is the one client both apps link; Brow reads and writes the same file.
/// Any read error is an empty ledger — a corrupt file must never block a poll.
public struct FileUsagePacingLedger: UsagePacingLedger {
    public static let defaultDirectory = NSHomeDirectory() + "/Library/Application Support/Grove"

    private let directory: String
    private var file: String { directory + "/oauth-usage-ledger.json" }

    public init(directory: String = FileUsagePacingLedger.defaultDirectory) {
        self.directory = directory
    }

    public func load() -> [String: UsagePacingRecord] {
        guard let data = FileManager.default.contents(atPath: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: UsagePacingRecord].self, from: data)) ?? [:]
    }

    public func store(_ record: UsagePacingRecord, for key: String) {
        var all = load()
        all[key] = record
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
    }
}

/// For tests, and for two clients in one process that should behave like two apps.
public final class InMemoryUsagePacingLedger: UsagePacingLedger, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: UsagePacingRecord] = [:]
    public init() {}
    public func load() -> [String: UsagePacingRecord] { lock.withLock { records } }
    public func store(_ record: UsagePacingRecord, for key: String) { lock.withLock { records[key] = record } }
}
