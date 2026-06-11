import Foundation
import GroveCore

// Pure aggregation for the Claude Sessions tab (spec §3/§4). No SwiftUI, no I/O.
// Joins a project snapshot's sessions (workspaces[] + loose[]) with their live
// processes by sessionId, derives a location and a primary action, and sorts
// for display. SessionsScreen renders the result as a snapshot-safe table.

/// Live status bucket of a session, or nil when the session has no live process
/// (then the row is "resumable"). busy/waiting/idle drive the colored dot and
/// the sort order; any unrecognised live status falls into `.idle`.
public enum SessionLiveStatus: String, Equatable, Sendable {
    case busy
    case waiting
    case idle

    /// Maps a LiveProcess.status string to a bucket. "shell" and anything
    /// unknown bucket as `.idle` (the calmest live colour).
    init(rawStatus: String) {
        switch rawStatus {
        case "busy": self = .busy
        case "waiting": self = .waiting
        default: self = .idle           // "idle", "shell", anything else
        }
    }

    /// Sort rank: busy < waiting < idle so a plain ascending sort puts the
    /// loudest status first.
    var sortRank: Int {
        switch self {
        case .busy: return 0
        case .waiting: return 1
        case .idle: return 2
        }
    }
}

/// Primary action for a session row.
/// - go: jump to the running cmux workspace hosting it.
/// - resume: relaunch Claude with --resume (in a fresh workspace).
public enum SessionRowAction: Equatable, Sendable {
    case go
    case resume
}

/// One row of the Claude Sessions table.
///
/// `id` is a composite of accountName + sessionId, NOT the raw session id: a
/// cross-account resume copies one session jsonl into a second account's
/// identical projects path, and the scanner flatMaps every account, so the same
/// `sessionId` legitimately appears twice in one container under two accounts.
/// Keying the Identifiable id on (accountName, sessionId) keeps SwiftUI's
/// ForEach well-defined and lets `findSession` resolve the right account's copy.
public struct SessionRow: Identifiable, Equatable, Sendable {
    /// Stable, unique per (accountName, sessionId). See type doc.
    public let id: String
    /// The raw Claude session id (NOT unique across accounts).
    public let sessionId: String
    public let title: String           // session title, or sessionId prefix(8)
    public let location: String        // workspace name / loose worktree leaf
    public let accountName: String
    public let cwd: String
    /// nil = no live process (resumable). Otherwise the live status bucket.
    public let liveStatus: SessionLiveStatus?
    /// Live process start time (for the runtime column); nil when not live or unknown.
    public let startedAt: Date?
    public let lastActivity: Date
    public let action: SessionRowAction
    /// For a `.go` row, the cmux workspace id to jump to (resolved from the hook
    /// map or a cmux workspace already sitting in the session's cwd). nil for
    /// `.resume` rows. Lets the UI selectWorkspace even on the cwd-only match
    /// path, instead of relaunching --resume in a fresh workspace.
    public let cmuxWorkspaceId: String?

    /// Composite Identifiable id from (accountName, sessionId). The NUL joiner
    /// can't appear in either field, so the pair maps injectively to a string.
    public static func rowID(account: String, session: String) -> String {
        account + "\u{0}" + session
    }

    public init(sessionId: String, title: String, location: String, accountName: String,
                cwd: String, liveStatus: SessionLiveStatus?, startedAt: Date?,
                lastActivity: Date, action: SessionRowAction, cmuxWorkspaceId: String? = nil) {
        self.id = SessionRow.rowID(account: accountName, session: sessionId)
        self.sessionId = sessionId
        self.title = title
        self.location = location
        self.accountName = accountName
        self.cwd = cwd
        self.liveStatus = liveStatus
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.action = action
        self.cmuxWorkspaceId = cmuxWorkspaceId
    }

    public var isLive: Bool { liveStatus != nil }
}

/// Builds the Claude Sessions table for one project snapshot.
///
/// Every session in `snapshot.workspaces[].sessions` and
/// `snapshot.loose[].sessions` becomes a row, joined to its live process by
/// sessionId within the SAME container. Action is `.go` when the session is
/// live AND it is either mapped in `cmuxMap` (the hook registry) OR some cmux
/// workspace in its container already lists the session's cwd; a `.go` row
/// carries that workspace's id so the UI can selectWorkspace directly. Otherwise
/// `.resume`. Rows sort live-first (busy, waiting, idle), then resumable by
/// lastActivity descending; ties break on title then id for determinism.
///
/// Dedup: a row is keyed by (accountName, sessionId). After a cross-account
/// resume the SAME sessionId exists under two accounts at one cwd, and the
/// scanner flatMaps every account, so a container can list it twice. Distinct
/// accounts both survive (two rows, unique ids); an exact (account, session)
/// repeat collapses to its first occurrence.
public func buildSessionRows(snapshot: ProjectSnapshot,
                             cmuxMap: [String: String]) -> [SessionRow] {
    var rows: [SessionRow] = []
    var seen: Set<String> = []          // (accountName, sessionId) composite ids

    func append(sessions: [ClaudeSession], live: [LiveProcess],
                cmux: [CmuxWorkspace], location: String) {
        // cmux workspaces in this container, keyed by the cwd they sit in.
        var cmuxByCwd: [String: String] = [:]
        for ws in cmux where cmuxByCwd[ws.currentDirectory] == nil {
            cmuxByCwd[ws.currentDirectory] = ws.id
        }
        for session in sessions {
            let key = SessionRow.rowID(account: session.accountName, session: session.id)
            guard seen.insert(key).inserted else { continue }   // dedup (account, session)
            let process = live.first { $0.sessionId == session.id }
            let liveStatus = process.map { SessionLiveStatus(rawStatus: $0.status) }
            // Resolve the cmux workspace to jump to: hook registry first, then a
            // cmux workspace already sitting in the session's cwd.
            let workspaceId = cmuxMap[session.id] ?? cmuxByCwd[session.cwd]
            let isGo = process != nil && workspaceId != nil
            let action: SessionRowAction = isGo ? .go : .resume
            let title = session.title.flatMap { $0.isEmpty ? nil : $0 }
                ?? String(session.id.prefix(8))
            rows.append(SessionRow(
                sessionId: session.id,
                title: title,
                location: location,
                accountName: session.accountName,
                cwd: session.cwd,
                liveStatus: liveStatus,
                startedAt: process?.startedAt,
                lastActivity: session.lastActivity,
                action: action,
                cmuxWorkspaceId: isGo ? workspaceId : nil))
        }
    }

    for workspace in snapshot.workspaces {
        append(sessions: workspace.sessions, live: workspace.liveProcesses,
               cmux: workspace.cmuxWorkspaces, location: workspace.name)
    }
    for loose in snapshot.loose {
        append(sessions: loose.sessions, live: loose.liveProcesses,
               cmux: loose.cmuxWorkspaces,
               location: (loose.entry.path as NSString).lastPathComponent)
    }

    rows.sort { lhs, rhs in
        switch (lhs.liveStatus, rhs.liveStatus) {
        case let (l?, r?):                       // both live: by status bucket
            if l.sortRank != r.sortRank { return l.sortRank < r.sortRank }
        case (.some, .none): return true         // live before resumable
        case (.none, .some): return false
        case (.none, .none):                     // both resumable: newest first
            if lhs.lastActivity != rhs.lastActivity {
                return lhs.lastActivity > rhs.lastActivity
            }
        }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        if lhs.sessionId != rhs.sessionId { return lhs.sessionId < rhs.sessionId }
        return lhs.accountName < rhs.accountName
    }
    return rows
}
