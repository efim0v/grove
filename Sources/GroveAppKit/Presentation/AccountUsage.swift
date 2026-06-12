import Foundation
import GroveCore

// Pure aggregation for the Accounts tab (spec §6.3). No SwiftUI, no I/O.

/// One drill-down row: where an account is active (workspace/worktree -> project).
public struct AccountUsageEntry: Equatable, Identifiable {
    public var id: String { project + "/" + location }
    public let project: String
    /// Workspace name, or the loose worktree's leaf directory name.
    public let location: String
    public let liveCount: Int
    public let sessionCount: Int

    public init(project: String, location: String, liveCount: Int, sessionCount: Int) {
        self.project = project
        self.location = location
        self.liveCount = liveCount
        self.sessionCount = sessionCount
    }
}

public struct AccountUsage: Equatable {
    /// Live Claude processes of this account across all loaded snapshots.
    public let liveCount: Int
    /// Scanned session transcripts of this account across all loaded snapshots.
    public let sessionCount: Int
    /// Per-location breakdown, most active first (live desc, sessions desc,
    /// then location name) so the order is deterministic regardless of the
    /// snapshots-dictionary iteration order.
    public let entries: [AccountUsageEntry]

    public init(liveCount: Int, sessionCount: Int, entries: [AccountUsageEntry]) {
        self.liveCount = liveCount
        self.sessionCount = sessionCount
        self.entries = entries
    }
}

/// Aggregates an account's activity over EVERY loaded project snapshot
/// (workspaces AND loose worktrees), matching by LiveProcess.accountName /
/// ClaudeSession.accountName. Locations with zero activity are omitted.
public func accountUsage(account: AccountConfig,
                         snapshots: [ProjectSnapshot]) -> AccountUsage {
    var entries: [AccountUsageEntry] = []
    for snapshot in snapshots {
        for workspace in snapshot.workspaces {
            let live = workspace.liveProcesses.filter { $0.accountName == account.name }.count
            let sessions = workspace.sessions.filter { $0.accountName == account.name }.count
            if live > 0 || sessions > 0 {
                entries.append(AccountUsageEntry(project: snapshot.project.name,
                                                 location: workspace.name,
                                                 liveCount: live, sessionCount: sessions))
            }
        }
        for loose in snapshot.loose {
            let live = loose.liveProcesses.filter { $0.accountName == account.name }.count
            let sessions = loose.sessions.filter { $0.accountName == account.name }.count
            if live > 0 || sessions > 0 {
                entries.append(AccountUsageEntry(
                    project: snapshot.project.name,
                    location: (loose.entry.path as NSString).lastPathComponent,
                    liveCount: live, sessionCount: sessions))
            }
        }
    }
    entries.sort { lhs, rhs in
        if lhs.liveCount != rhs.liveCount { return lhs.liveCount > rhs.liveCount }
        if lhs.sessionCount != rhs.sessionCount { return lhs.sessionCount > rhs.sessionCount }
        if lhs.location != rhs.location { return lhs.location < rhs.location }
        return lhs.project < rhs.project
    }
    return AccountUsage(liveCount: entries.reduce(0) { $0 + $1.liveCount },
                        sessionCount: entries.reduce(0) { $0 + $1.sessionCount },
                        entries: entries)
}

public struct WorkspaceUsage: Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cost: Double
    public let activeAccounts: [String]   // accounts with usage at this workspace's cwd
}

/// Aggregates per-account analytics for ONE workspace by its umbrella cwd.
public func workspaceUsage(workspace: FeatureWorkspace,
                           analyticsByAccount: [String: AccountUsageAnalytics]) -> WorkspaceUsage {
    let cwd = workspace.umbrellaPath
    var input = 0, output = 0; var cost = 0.0; var accounts: Set<String> = []
    for (name, a) in analyticsByAccount {
        // match the umbrella cwd OR any cwd nested under it (sessions can be in subdirs).
        for (c, t) in a.byCwd where c == cwd || c.hasPrefix(cwd + "/") {
            input += t.inputTokens; output += t.outputTokens; cost += t.cost
            accounts.insert(name)
        }
    }
    return WorkspaceUsage(inputTokens: input, outputTokens: output, cost: cost,
                          activeAccounts: accounts.sorted())
}
