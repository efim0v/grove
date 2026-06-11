import Foundation
import GroveCore

/// Most recent activity of a workspace: the newest of its session-activity
/// dates and per-repo last-commit dates. nil = no data at all.
public func recencyDate(_ workspace: FeatureWorkspace) -> Date? {
    let sessionDates = workspace.sessions.map(\.lastActivity)
    let commitDates = workspace.repos.compactMap { $0.meta?.lastCommitDate }
    return (sessionDates + commitDates).max()
}

/// Flat-list ordering (spec §6.1 "≡ список"): newest activity first, rows
/// without any date sink to the bottom, ties break alphabetically by name
/// so the output is stable.
public func flattenByRecency(_ rows: [WorkspaceTreeRow]) -> [WorkspaceTreeRow] {
    rows.sorted { lhs, rhs in
        let l = recencyDate(lhs.workspace) ?? .distantPast
        let r = recencyDate(rhs.workspace) ?? .distantPast
        if l != r { return l > r }
        return lhs.name < rhs.name
    }
}
