import Foundation

// Pure text formatters used by grove-cli. Public so they are unit-testable
// and reusable; they never touch git or the filesystem.

public func renderSnapshotTree(_ snapshot: ProjectSnapshot) -> String {
    var lines: [String] = []
    lines.append("\(snapshot.project.name) — \(snapshot.repos.count) repo(s), \(snapshot.workspaces.count) workspace(s)")

    let names = Set(snapshot.workspaces.map { $0.name })
    var children: [String: [FeatureWorkspace]] = [:]
    var roots: [FeatureWorkspace] = []
    for workspace in snapshot.workspaces.sorted(by: { $0.name < $1.name }) {
        if let parent = workspace.parentName, names.contains(parent) {
            children[parent, default: []].append(workspace)
        } else {
            roots.append(workspace)
        }
    }

    func nodeLabel(_ workspace: FeatureWorkspace) -> String {
        let branch = workspace.repos.first?.entry.branch ?? "?"
        let dirty = workspace.repos.compactMap { $0.meta?.dirtyCount }.reduce(0, +)
        let dirtyMark = dirty > 0 ? "✎\(dirty)" : "✓"
        var label = "● \(workspace.name) (\(branch)) \(dirtyMark) · \(workspace.repos.count) repo(s)"
        if !workspace.nestedWorktrees.isEmpty { label += " (+\(workspace.nestedWorktrees.count) nested)" }
        if !workspace.liveProcesses.isEmpty { label += " · \(workspace.liveProcesses.count) live" }
        if !workspace.sessions.isEmpty { label += " · \(workspace.sessions.count) session(s)" }
        return label
    }

    // Inconsistent parent data can form cycles (e.g. alpha->beta and beta->alpha):
    // cycle members are never roots and never reached from one, so a naive walk
    // would drop them silently. Promote one representative per unreached cycle
    // (in name order) to an additional root, mirroring the missing-parent defense.
    var reachable = Set<String>()
    func markReachable(_ workspace: FeatureWorkspace) {
        guard reachable.insert(workspace.name).inserted else { return }
        for kid in children[workspace.name] ?? [] { markReachable(kid) }
    }
    for root in roots { markReachable(root) }
    for workspace in snapshot.workspaces.sorted(by: { $0.name < $1.name })
    where !reachable.contains(workspace.name) {
        roots.append(workspace)
        markReachable(workspace)
    }

    var visited = Set<String>()
    func render(_ workspace: FeatureWorkspace, prefix: String, isLast: Bool) {
        visited.insert(workspace.name)
        let connector = isLast ? "└─" : "├─"
        lines.append(prefix + connector + nodeLabel(workspace))
        // Skip already-visited kids so cycle back-edges cannot recurse forever.
        let kids = (children[workspace.name] ?? []).filter { !visited.contains($0.name) }
        let childPrefix = prefix + (isLast ? "  " : "│ ")
        for (index, kid) in kids.enumerated() {
            render(kid, prefix: childPrefix, isLast: index == kids.count - 1)
        }
    }

    for (index, root) in roots.enumerated() {
        render(root, prefix: "", isLast: index == roots.count - 1)
    }

    if !snapshot.loose.isEmpty {
        lines.append("")
        lines.append("Loose worktrees (\(snapshot.loose.count))")
        for loose in snapshot.loose.sorted(by: { $0.entry.path < $1.entry.path }) {
            let branch = loose.entry.branch ?? "detached"
            lines.append("  \(loose.entry.path) — \(loose.repo.dirName) @ \(branch)")
        }
    }

    if !snapshot.errors.isEmpty {
        lines.append("")
        lines.append("Errors (\(snapshot.errors.count))")
        for error in snapshot.errors {
            lines.append("  ⚠ \(error)")
        }
    }

    return lines.joined(separator: "\n")
}

public func renderSessions(_ sessions: [ClaudeSession], live: [LiveProcess]) -> String {
    if sessions.isEmpty && live.isEmpty { return "no sessions" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")

    var lines: [String] = []
    var liveById: [String: LiveProcess] = [:]
    for process in live where liveById[process.sessionId] == nil {
        liveById[process.sessionId] = process
    }

    for session in sessions {
        let marker: String
        if let process = liveById[session.id] {
            marker = "● \(process.status)"
        } else {
            marker = "○ resumable"
        }
        let title = session.title ?? session.id
        let branch = session.gitBranch.map { " [\($0)]" } ?? ""
        lines.append("\(marker)  \(title)\(branch)  \(session.accountName)  \(formatter.string(from: session.lastActivity))")
    }

    let sessionIds = Set(sessions.map { $0.id })
    for process in live where !sessionIds.contains(process.sessionId) {
        lines.append("● \(process.status)  pid \(process.pid)  \(process.accountName)  \(process.cwd)")
    }

    return lines.joined(separator: "\n")
}

public func renderGraph(_ nodes: [CommitNode]) -> String {
    var lines: [String] = []
    for node in nodes {
        let indent = String(repeating: "| ", count: node.lane)
        let short = String(node.hash.prefix(7))
        let refs = node.refs.isEmpty ? "" : " (" + node.refs.joined(separator: ", ") + ")"
        lines.append("\(indent)* \(short)\(refs) \(node.subject)")
    }
    return lines.joined(separator: "\n")
}
