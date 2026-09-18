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
/// `id` is a composite of cwd + sessionId, NOT the raw session id: with a shared
/// store the SAME sessionId at one cwd is listed under EVERY linked account, so
/// the scanner flatMaps the same `(cwd, sessionId)` once per account. Collapsing
/// on (cwd, sessionId) makes a shared session ONE row whose `accounts` set carries
/// every account it is reachable under, keeping SwiftUI's ForEach well-defined.
public struct SessionRow: Identifiable, Equatable, Sendable {
    /// Stable, unique per (cwd, sessionId). See type doc.
    public let id: String
    /// The raw Claude session id (NOT unique across accounts).
    public let sessionId: String
    public let title: String           // session title, or sessionId prefix(8)
    public let location: String        // workspace name / loose worktree leaf
    public let accountName: String
    /// Every account this session is reachable under (a shared session is listed
    /// under every linked account). Sorted for determinism; always contains
    /// `accountName`. Single-account sessions hold exactly `[accountName]`.
    public let accounts: [String]
    public let cwd: String
    /// nil = no live process (resumable). Otherwise the live status bucket.
    public let liveStatus: SessionLiveStatus?
    /// Live process start time (for the runtime column); nil when not live or unknown.
    public let startedAt: Date?
    public let lastActivity: Date
    /// Git branch the session was opened on (from the transcript's first user
    /// record); nil when unknown. Shown next to the location.
    public let gitBranch: String?
    /// Session creation moment (first transcript timestamp) — "created Nd ago".
    public let createdAt: Date?
    /// Human-prompt count — "N turns".
    public let turnCount: Int
    /// Last model the session ran on — shown short (e.g. "opus-4-8").
    public let model: String?
    public let action: SessionRowAction
    /// For a `.go` row, the cmux workspace id to jump to (resolved from the hook
    /// map or a cmux workspace already sitting in the session's cwd). nil for
    /// `.resume` rows. Lets the UI selectWorkspace even on the cwd-only match
    /// path, instead of relaunching --resume in a fresh workspace.
    public let cmuxWorkspaceId: String?

    /// Stable Identifiable id for a collapsed session: (cwd, sessionId). A shared
    /// session at one cwd is ONE row no matter how many accounts list it. The NUL
    /// joiner can't appear in either field, so the pair maps injectively.
    public static func rowID(cwd: String, session: String) -> String {
        cwd + "\u{0}" + session
    }

    public init(sessionId: String, title: String, location: String, accountName: String,
                accounts: [String] = [],
                cwd: String, liveStatus: SessionLiveStatus?, startedAt: Date?,
                lastActivity: Date, action: SessionRowAction, cmuxWorkspaceId: String? = nil,
                gitBranch: String? = nil, createdAt: Date? = nil,
                turnCount: Int = 0, model: String? = nil) {
        self.id = SessionRow.rowID(cwd: cwd, session: sessionId)
        self.sessionId = sessionId
        self.title = title
        self.location = location
        self.accountName = accountName
        self.accounts = accounts.isEmpty ? [accountName] : accounts
        self.cwd = cwd
        self.liveStatus = liveStatus
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.gitBranch = gitBranch
        self.createdAt = createdAt
        self.turnCount = turnCount
        self.model = model
        self.action = action
        self.cmuxWorkspaceId = cmuxWorkspaceId
    }

    public var isLive: Bool { liveStatus != nil }
}

/// Distinct account names of a session group, in first-seen order then sorted
/// for a stable chip layout. Always non-empty.
private func orderedUniqueAccounts(_ sessions: [ClaudeSession]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for s in sessions where seen.insert(s.accountName).inserted { result.append(s.accountName) }
    return result.sorted()
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
/// Collapse: a row is keyed by (cwd, sessionId). With a shared store the SAME
/// sessionId at one cwd is listed under EVERY linked account, and the scanner
/// flatMaps every account, so the same (cwd, sessionId) occurs once per account
/// AND possibly in more than one container. Those occurrences collapse GLOBALLY
/// into ONE row whose `accounts` set carries every account it is reachable under;
/// the primary `accountName` is the live owner if any occurrence is live, else
/// first-seen.
public func buildSessionRows(snapshot: ProjectSnapshot,
                             cmuxMap: [String: String]) -> [SessionRow] {
    var rows: [SessionRow] = []

    /// One flattened occurrence of a session in some container, carrying the
    /// container's live processes and location label so global grouping keeps them.
    struct Occurrence {
        let session: ClaudeSession
        let live: [LiveProcess]
        let cmux: [CmuxWorkspace]
        let location: String
    }

    // 1) Flatten EVERY occurrence across all containers (workspaces + loose) first.
    var occurrences: [Occurrence] = []
    func collect(sessions: [ClaudeSession], live: [LiveProcess],
                 cmux: [CmuxWorkspace], location: String) {
        for session in sessions {
            occurrences.append(Occurrence(session: session, live: live, cmux: cmux, location: location))
        }
    }

    for workspace in snapshot.workspaces {
        collect(sessions: workspace.sessions, live: workspace.liveProcesses,
                cmux: workspace.cmuxWorkspaces, location: workspace.name)
    }
    for loose in snapshot.loose {
        collect(sessions: loose.sessions, live: loose.liveProcesses,
                cmux: loose.cmuxWorkspaces,
                location: (loose.entry.path as NSString).lastPathComponent)
    }

    // 2) Group GLOBALLY by (cwd, sessionId), preserving first-seen order. The account
    //    of EVERY occurrence is merged into the row's set — no container is dropped.
    var order: [String] = []
    var grouped: [String: [Occurrence]] = [:]
    for occ in occurrences {
        let key = SessionRow.rowID(cwd: occ.session.cwd, session: occ.session.id)
        if grouped[key] == nil { order.append(key) }
        grouped[key, default: []].append(occ)
    }

    // 3) One row per key. Primary account = the live owner if any occurrence is live,
    //    else first-seen. accounts = the merged set across ALL occurrences/containers.
    for key in order {
        let group = grouped[key]!
        let firstOcc = group[0]
        let first = firstOcc.session
        // First live process for this session across any occurrence in the group —
        // by sessionId OR (for a fresh, empty-id process) the canonicalized cwd, so a
        // bare `claude` running at the session's directory reads as live here too.
        let liveOcc = group.first { occ in occ.live.liveProcess(forSessionId: first.id, cwd: first.cwd) != nil }
        let process = liveOcc?.live.liveProcess(forSessionId: first.id, cwd: first.cwd)
        // Primary account: the live owner if its account is among the group, else first-seen.
        let liveOwner = process.flatMap { p in
            group.map(\.session).first { $0.accountName == p.accountName }
        }
        let primary = liveOwner ?? first
        let accounts = orderedUniqueAccounts(group.map(\.session))
        // Location/cmux come from the occurrence that owns the live process if any,
        // else the first occurrence (stable).
        let owningOcc = liveOcc ?? firstOcc
        var cmuxByCwd: [String: String] = [:]
        for ws in owningOcc.cmux where cmuxByCwd[ws.currentDirectory] == nil {
            cmuxByCwd[ws.currentDirectory] = ws.id
        }
        let liveStatus = process.map { SessionLiveStatus(rawStatus: $0.status) }
        let workspaceId = cmuxMap[first.id] ?? cmuxByCwd[first.cwd]
        let isGo = process != nil && workspaceId != nil
        let action: SessionRowAction = isGo ? .go : .resume
        let title = first.title.flatMap { $0.isEmpty ? nil : $0 }
            ?? String(first.id.prefix(8))
        rows.append(SessionRow(
            sessionId: first.id,
            title: title,
            location: owningOcc.location,
            accountName: primary.accountName,
            accounts: accounts,
            cwd: first.cwd,
            liveStatus: liveStatus,
            startedAt: process?.startedAt,
            lastActivity: first.lastActivity,
            action: action,
            cmuxWorkspaceId: isGo ? workspaceId : nil,
            gitBranch: first.gitBranch,
            createdAt: first.createdAt,
            turnCount: first.turnCount,
            model: first.model))
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

// MARK: - External session rows (Part A)

/// Returns `SessionRow`s for sessions discovered externally (via `refreshSessionIndex`'s
/// disk-wide scan) that are NOT already represented in `snapshotRows` — i.e., whose
/// `(cwd, sessionId)` composite key does not already appear in the current project
/// snapshot. This prevents listing the same session twice when it happens to be inside
/// a scanned workspace.
///
/// The returned rows carry the full `cwd` and `accountName` so Task 4 ("Share / adopt"
/// affordance) can use them directly. All rows have `.resume` action (external sessions
/// have no live-process information at this stage).
///
/// Input order is preserved (the caller supplies sessions newest-first from
/// `allRecentSessions`). Location label is the leaf directory of each session's `cwd`.
public func buildExternalSessionRows(snapshotRows: [SessionRow],
                                     externalSessions: [ClaudeSession]) -> [SessionRow] {
    let shownKeys = Set(snapshotRows.map { SessionRow.rowID(cwd: $0.cwd, session: $0.sessionId) })
    var result: [SessionRow] = []
    for s in externalSessions {
        let key = SessionRow.rowID(cwd: s.cwd, session: s.id)
        guard !shownKeys.contains(key) else { continue }
        let location = (s.cwd as NSString).lastPathComponent
        let title = s.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(s.id.prefix(8))
        result.append(SessionRow(
            sessionId: s.id,
            title: title,
            location: location,
            accountName: s.accountName,
            accounts: [s.accountName],
            cwd: s.cwd,
            liveStatus: nil,
            startedAt: nil,
            lastActivity: s.lastActivity,
            action: .resume,
            cmuxWorkspaceId: nil,
            gitBranch: s.gitBranch,
            createdAt: s.createdAt,
            turnCount: s.turnCount,
            model: s.model))
    }
    return result
}

// MARK: - Other session rows (Part B)

/// Converts `otherSessions` (sessions matching no configured project) into `SessionRow`s
/// for display in the "Other sessions" bucket. Input order is preserved (newest-first from
/// the caller). Location label is the leaf directory of each session's `cwd`. All rows
/// have `.resume` action.
public func buildOtherSessionRows(sessions: [ClaudeSession]) -> [SessionRow] {
    sessions.map { s in
        let location = (s.cwd as NSString).lastPathComponent
        let title = s.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(s.id.prefix(8))
        return SessionRow(
            sessionId: s.id,
            title: title,
            location: location,
            accountName: s.accountName,
            accounts: [s.accountName],
            cwd: s.cwd,
            liveStatus: nil,
            startedAt: nil,
            lastActivity: s.lastActivity,
            action: .resume,
            cmuxWorkspaceId: nil,
            gitBranch: s.gitBranch,
            createdAt: s.createdAt,
            turnCount: s.turnCount,
            model: s.model)
    }
}
