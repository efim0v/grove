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

// MARK: - Tree rows

public struct WorkspaceTreeRow: Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let workspace: FeatureWorkspace
    /// 0 = root (forked straight from base branches).
    public let depth: Int
    /// One flag per ancestor level (count == depth): true when that ancestor
    /// lineage keeps a continuing "│" lane below this row (i.e. the ancestor
    /// at that level is NOT the last among its siblings).
    public let ancestorContinues: [Bool]
    /// True when this row is the last among its own siblings.
    public let isLast: Bool
    public let badges: WorkspaceBadges

    public init(name: String, workspace: FeatureWorkspace, depth: Int,
                ancestorContinues: [Bool], isLast: Bool, badges: WorkspaceBadges) {
        self.name = name
        self.workspace = workspace
        self.depth = depth
        self.ancestorContinues = ancestorContinues
        self.isLast = isLast
        self.badges = badges
    }
}

/// Flattens the snapshot's workspaces into DFS pre-order rows.
///
/// Roots are workspaces whose parentName is nil, unknown (not in the snapshot),
/// self-referential, or part of a parent cycle. Cycle handling: a workspace
/// whose parent chain leads back to itself sits ON a cycle — its parent edge is
/// cut, so every cycle member becomes a root, while workspaces hanging BELOW
/// the cycle keep their edge and stay attached. Roots and children are sorted
/// by name; every workspace appears exactly once.
public func buildWorkspaceTree(_ snapshot: ProjectSnapshot, now: Date) -> [WorkspaceTreeRow] {
    let byName = Dictionary(snapshot.workspaces.map { ($0.name, $0) },
                            uniquingKeysWith: { first, _ in first })

    // Resolved parent edges: the parent must exist and differ from the child.
    var parent: [String: String] = [:]
    for ws in byName.values {
        if let p = ws.parentName, p != ws.name, byName[p] != nil {
            parent[ws.name] = p
        }
    }

    // Cut the edge of every node that is ON a cycle (walking its ancestor chain
    // returns to the node itself). The step bound makes the walk total even on
    // arbitrary inconsistent input.
    var onCycle: Set<String> = []
    for name in byName.keys {
        var current = parent[name]
        var steps = 0
        while let p = current, steps <= byName.count {
            if p == name {
                onCycle.insert(name)
                break
            }
            current = parent[p]
            steps += 1
        }
    }
    for name in onCycle {
        parent.removeValue(forKey: name)
    }

    var children: [String: [String]] = [:]
    for (child, p) in parent {
        children[p, default: []].append(child)
    }
    for key in children.keys {
        children[key]?.sort()
    }
    let roots = byName.keys.filter { parent[$0] == nil }.sorted()

    var rows: [WorkspaceTreeRow] = []
    func visit(_ name: String, depth: Int, ancestorContinues: [Bool], isLast: Bool) {
        guard let ws = byName[name] else { return }
        rows.append(WorkspaceTreeRow(name: name, workspace: ws, depth: depth,
                                     ancestorContinues: ancestorContinues, isLast: isLast,
                                     badges: badges(for: ws, now: now)))
        let kids = children[name] ?? []
        for (index, kid) in kids.enumerated() {
            visit(kid, depth: depth + 1,
                  ancestorContinues: ancestorContinues + [!isLast],
                  isLast: index == kids.count - 1)
        }
    }
    for (index, root) in roots.enumerated() {
        visit(root, depth: 0, ancestorContinues: [], isLast: index == roots.count - 1)
    }
    return rows
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

// MARK: - Search filter

/// Case-insensitive substring filter over workspace names and per-repo branch
/// names. A kept row's ancestors are always kept too (so the tree stays
/// connected); descendants of a match are kept only if they match themselves.
/// An empty / whitespace-only query returns the rows unchanged.
public func filterTree(_ rows: [WorkspaceTreeRow], query: String) -> [WorkspaceTreeRow] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return rows }

    func matches(_ row: WorkspaceTreeRow) -> Bool {
        if row.name.lowercased().contains(needle) { return true }
        return row.workspace.repos.contains { state in
            state.entry.branch?.lowercased().contains(needle) == true
        }
    }

    // Rows are DFS pre-order, so a stack of row indices keyed by depth is
    // exactly the ancestor chain of the current row.
    var keep = Set<Int>()
    var stack: [Int] = []
    for (index, row) in rows.enumerated() {
        while stack.count > row.depth { stack.removeLast() }
        stack.append(index)
        if matches(row) { keep.formUnion(stack) }
    }
    return rows.enumerated().filter { keep.contains($0.offset) }.map { $0.element }
}
