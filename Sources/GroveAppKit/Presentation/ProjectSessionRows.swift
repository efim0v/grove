import Foundation
import GroveCore

// Pure presentation for the Projects tab's per-project session previews (items
// 4/7). Joins the cheap recent-session index with live processes + the cmux hook
// map to produce a user-facing status (running / waiting / closed) and a one-tap
// terminal target (Go to the cmux workspace, or Resume).

/// One session preview block under a project card.
public struct ProjectSessionRow: Sendable, Equatable, Identifiable {
    /// User-facing status trio (item 7): "выполняется / ожидает / закрыта".
    public enum Status: String, Sendable, Equatable {
        case running    // a live process, busy or idle
        case waiting    // a live process awaiting input
        case closed     // no live process (resumable)
    }

    public var id: String { cwd + "\u{0}" + sessionId }
    public let sessionId: String
    public let title: String
    public let cwd: String
    public let location: String          // leaf directory of the cwd
    public let accountName: String
    public let lastActivity: Date
    public let status: Status
    /// cmux workspace hosting the session, if any — present -> "Go", nil -> "Resume".
    public let cmuxWorkspaceId: String?

    public var canGo: Bool { cmuxWorkspaceId != nil }

    public init(sessionId: String, title: String, cwd: String, location: String,
                accountName: String, lastActivity: Date, status: Status,
                cmuxWorkspaceId: String?) {
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.location = location
        self.accountName = accountName
        self.lastActivity = lastActivity
        self.status = status
        self.cmuxWorkspaceId = cmuxWorkspaceId
    }
}

/// Joins recent `sessions` with `live` processes (by sessionId) and the cmux hook
/// `cmuxMap` to status + a Go/Resume target. `closed` = no live process.
public func buildProjectSessionRows(sessions: [ClaudeSession],
                                    live: [LiveProcess],
                                    cmuxMap: [String: String]) -> [ProjectSessionRow] {
    let liveBySession = Dictionary(live.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
    return sessions.map { s in
        let process = liveBySession[s.id]
        let status: ProjectSessionRow.Status
        switch process.map({ SessionLiveStatus(rawStatus: $0.status) }) {
        case .some(.waiting): status = .waiting
        case .some:           status = .running     // busy or idle, both "running"
        case nil:             status = .closed
        }
        let title = (s.title?.isEmpty == false) ? s.title! : String(s.id.prefix(8))
        return ProjectSessionRow(
            sessionId: s.id,
            title: title,
            cwd: s.cwd,
            location: (s.cwd as NSString).lastPathComponent,
            accountName: s.accountName,
            lastActivity: s.lastActivity,
            status: status,
            cmuxWorkspaceId: cmuxMap[s.id])
    }
}
