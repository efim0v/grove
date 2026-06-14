import Foundation

/// One sampled point on a project's code-stats timeline. `date` is the sample's
/// wall-clock instant; the line/file counts are the scan totals at that moment.
public struct CodeStatsPoint: Codable, Sendable, Equatable {
    public let date: Date
    public let totalLines: Int
    public let code: Int
    public let comment: Int
    public let blank: Int
    public let totalFiles: Int
    public init(date: Date, totalLines: Int, code: Int, comment: Int, blank: Int, totalFiles: Int) {
        self.date = date
        self.totalLines = totalLines
        self.code = code
        self.comment = comment
        self.blank = blank
        self.totalFiles = totalFiles
    }
}

/// A project's full code-stats history: an append-only series of points, oldest
/// first. Plotted as the "lines over time" chart.
public struct CodeStatsHistory: Codable, Sendable, Equatable {
    public var points: [CodeStatsPoint]
    public init(points: [CodeStatsPoint] = []) {
        self.points = points
    }
}

/// Persists one `CodeStatsHistory` JSON file per project under `dir`, keyed by the
/// project's UUID. Mirrors `ConfigStore`'s durability story: atomic temp-write +
/// rename on save, graceful (return-empty) recovery from a missing or corrupt file.
public final class CodeStatsStore {
    private let dir: URL

    /// `dir` is the directory that holds the per-project `<uuid>.json` files.
    /// Injectable so tests can point at a temp dir.
    public init(dir: URL) {
        self.dir = dir
    }

    private func url(for projectID: UUID) -> URL {
        dir.appendingPathComponent("\(projectID.uuidString).json")
    }

    /// Load a project's history. Missing file -> empty history. Corrupt file ->
    /// empty history (we never crash on bad data; the next append rewrites it).
    public func load(projectID: UUID) -> CodeStatsHistory {
        let url = url(for: projectID)
        guard let data = try? Data(contentsOf: url) else { return CodeStatsHistory() }
        guard let history = try? JSONDecoder().decode(CodeStatsHistory.self, from: data) else {
            return CodeStatsHistory()
        }
        return history
    }

    /// Delete a project's history file. Missing file -> no-op (never throws): called
    /// when a project is removed so its series doesn't linger on disk.
    public func delete(projectID: UUID) {
        try? FileManager.default.removeItem(at: url(for: projectID))
    }

    /// Coalesce `point` into the project's history and persist it. See
    /// `coalesce` for the append-vs-replace rule. `minInterval` is the smallest gap
    /// between two distinct samples (the 15s scan loop replaces the trailing point
    /// when nothing changed, so the file doesn't bloat with identical rows).
    public func append(projectID: UUID, point: CodeStatsPoint, minInterval: TimeInterval = 3600) throws {
        let history = load(projectID: projectID)
        let updated = Self.coalesce(history: history, newPoint: point, minInterval: minInterval)
        try save(projectID: projectID, history: updated)
    }

    /// Atomic save: temp file in `dir`, then rename over the target. Creates `dir`.
    public func save(projectID: UUID, history: CodeStatsHistory) throws {
        let fm = FileManager.default
        let url = url(for: projectID)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(history)
            let tmp = dir.appendingPathComponent("\(url.lastPathComponent).tmp-\(UUID().uuidString)")
            try data.write(to: tmp, options: [])
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            throw GroveError.io("failed to save code stats to \(url.path): \(error.localizedDescription)")
        }
    }

    /// Pure history update. Append `newPoint` only when it carries NEW information —
    /// any of the counts changed versus the last point, OR at least `minInterval`
    /// has elapsed since the last point's `date`. Otherwise REPLACE the trailing
    /// point with `newPoint` (keeps the latest timestamp without growing the series).
    /// An empty history always appends.
    public static func coalesce(history: CodeStatsHistory, newPoint: CodeStatsPoint,
                                minInterval: TimeInterval) -> CodeStatsHistory {
        var points = history.points
        guard let last = points.last else {
            points.append(newPoint)
            return CodeStatsHistory(points: points)
        }
        let changed = last.totalLines != newPoint.totalLines
            || last.code != newPoint.code
            || last.comment != newPoint.comment
            || last.blank != newPoint.blank
            || last.totalFiles != newPoint.totalFiles
        let elapsed = newPoint.date.timeIntervalSince(last.date)
        if changed || elapsed >= minInterval {
            points.append(newPoint)
        } else {
            points[points.count - 1] = newPoint
        }
        return CodeStatsHistory(points: points)
    }
}
