import Foundation
import GroveCore

// Pure presentation logic for the Workspaces tree. No SwiftUI, no I/O:
// everything here takes core snapshot values plus an injected `now` and is
// fully unit-tested in GroveAppKitTests.

// MARK: - Age buckets (spec §6.1 traffic light: 🟢 < 7d, 🟠 < 21d, 🔴 older)

public enum AgeBucket: Equatable {
    case fresh    // age < 7 days
    case aging    // 7 days <= age < 21 days
    case stale    // age >= 21 days
    case unknown  // no fork-date data in any repo
}

// MARK: - Claude activity (LiveProcess.status -> badge category)

public enum ClaudeActivity: Equatable {
    case busy
    case waiting
    case idle

    /// "busy" -> .busy, "waiting" -> .waiting, anything else ("idle", "shell",
    /// unknown future values) -> .idle.
    public init(status: String) {
        switch status {
        case "busy": self = .busy
        case "waiting": self = .waiting
        default: self = .idle
        }
    }
}

// MARK: - Badges

public struct WorkspaceBadges: Equatable {
    /// Whole days since the OLDEST fork point across the workspace's repos
    /// (max over repos' meta.forkDate measured against `now`); nil when no
    /// repo carries a fork date.
    public let ageDays: Int?
    public let ageBucket: AgeBucket
    /// Sum of repos' meta.dirtyCount (repos without meta contribute 0).
    public let dirtyTotal: Int
    /// Live Claude processes with status "busy".
    public let busyCount: Int
    /// Live Claude processes with status "waiting".
    public let waitingCount: Int
    /// Sessions with NO matching live process (matched by session id).
    public let resumableCount: Int

    public init(ageDays: Int?, ageBucket: AgeBucket, dirtyTotal: Int,
                busyCount: Int, waitingCount: Int, resumableCount: Int) {
        self.ageDays = ageDays
        self.ageBucket = ageBucket
        self.dirtyTotal = dirtyTotal
        self.busyCount = busyCount
        self.waitingCount = waitingCount
        self.resumableCount = resumableCount
    }
}

public func badges(for ws: FeatureWorkspace, now: Date) -> WorkspaceBadges {
    let forkAges: [Int] = ws.repos.compactMap { state in
        guard let forkDate = state.meta?.forkDate else { return nil }
        return max(0, Int(now.timeIntervalSince(forkDate) / 86_400))
    }
    let ageDays = forkAges.max()

    let ageBucket: AgeBucket
    switch ageDays {
    case .none: ageBucket = .unknown
    case .some(let days) where days < 7: ageBucket = .fresh
    case .some(let days) where days < 21: ageBucket = .aging
    case .some: ageBucket = .stale
    }

    let dirtyTotal = ws.repos.reduce(0) { $0 + ($1.meta?.dirtyCount ?? 0) }

    var busyCount = 0
    var waitingCount = 0
    for process in ws.liveProcesses {
        switch ClaudeActivity(status: process.status) {
        case .busy: busyCount += 1
        case .waiting: waitingCount += 1
        case .idle: break
        }
    }

    let liveSessionIds = Set(ws.liveProcesses.map { $0.sessionId })
    let resumableCount = ws.sessions.filter { !liveSessionIds.contains($0.id) }.count

    return WorkspaceBadges(ageDays: ageDays, ageBucket: ageBucket, dirtyTotal: dirtyTotal,
                           busyCount: busyCount, waitingCount: waitingCount,
                           resumableCount: resumableCount)
}

// MARK: - Relative age ("5m", "3h", "2d", "5w")

/// Coarse relative age for session/commit rows. Buckets: minutes below one
/// hour, hours below one day, days below one week, whole weeks after that.
/// `date` in the future clamps to "0m".
public func relativeAge(_ date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 7 { return "\(days)d" }
    return "\(days / 7)w"
}
