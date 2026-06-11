import Foundation
import GroveCore

// Pure presentation logic for the Graph tab (spec §6.2). No SwiftUI, no I/O.

// MARK: - Ref chips

/// Origin of a `%D` ref, in display priority order.
public enum RefKind: Equatable {
    case head    // "HEAD -> branch" (or detached "HEAD")
    case local   // plain local branch name
    case remote  // "origin/..." (v1 marks the conventional remote prefix only)
    case tag     // "tag: name"
}

/// One capsule chip on a commit row. `branch` is the name usable for branch
/// actions (create workspace / open Claude): the checked-out branch for HEAD
/// chips, the name without "origin/" for remote chips, nil for tags and a
/// detached HEAD.
public struct RefChip: Equatable, Identifiable {
    public var id: String { rawRef }
    /// Verbatim ref as emitted by git (`%D` component).
    public let rawRef: String
    public let kind: RefKind
    /// Display text ("dev", "origin/dev", "v0.4.0").
    public let name: String
    public let branch: String?

    public init(rawRef: String, kind: RefKind, name: String, branch: String?) {
        self.rawRef = rawRef
        self.kind = kind
        self.name = name
        self.branch = branch
    }
}

/// Classifies CommitNode.refs into chips, preserving git's order.
/// "HEAD -> x" -> head(x); bare "HEAD" -> detached head (no branch);
/// "tag: t" -> tag(t); "origin/x" -> remote (branch = x); else local.
public func refChips(_ refs: [String]) -> [RefChip] {
    refs.map { ref in
        if ref == "HEAD" {
            return RefChip(rawRef: ref, kind: .head, name: "HEAD", branch: nil)
        }
        if ref.hasPrefix("HEAD -> ") {
            let branch = String(ref.dropFirst("HEAD -> ".count))
            return RefChip(rawRef: ref, kind: .head, name: branch, branch: branch)
        }
        if ref.hasPrefix("tag: ") {
            return RefChip(rawRef: ref, kind: .tag,
                           name: String(ref.dropFirst("tag: ".count)), branch: nil)
        }
        if ref.hasPrefix("origin/") {
            return RefChip(rawRef: ref, kind: .remote, name: ref,
                           branch: String(ref.dropFirst("origin/".count)))
        }
        return RefChip(rawRef: ref, kind: .local, name: ref, branch: ref)
    }
}

// MARK: - Branch -> workspace-name prefill

/// Default workspace name when creating from a branch: the leaf path component
/// ("feat/media-upload" -> "media-upload"), with every character outside
/// GroveCore's ^[A-Za-z0-9._-]+$ name rule replaced by "-". Empty leaves
/// (e.g. branch "/") fall back to "workspace".
public func sanitizedWorkspaceName(fromBranch branch: String) -> String {
    let leaf = branch.split(separator: "/").last.map(String.init) ?? ""
    let sanitized = String(leaf.map { char -> Character in
        if let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1 {
            let v = scalar.value
            let allowed = (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A)
                || (v >= 0x61 && v <= 0x7A) || char == "." || char == "_" || char == "-"
            if allowed { return char }
        }
        return "-"
    })
    return sanitized.isEmpty ? "workspace" : sanitized
}

// MARK: - Graph repo auto-selection

/// Repo the Graph tab should auto-load: the snapshot's first repo when the
/// current selection is nil or STALE (not among the snapshot's repos — e.g.
/// left over from a previously selected project, v1.2.1 fix 1); nil when the
/// selection is still valid or there is nothing to select (no reload needed).
public func graphAutoSelectRepo(current: String?, repos: [RepoInfo]) -> RepoInfo? {
    if let current, repos.contains(where: { $0.path == current }) { return nil }
    return repos.first
}

// MARK: - Branch -> existing worktree lookup

/// Where a branch is already checked out, for "Open Claude in worktree of this
/// branch" (spec §6.2). cwd is the workspace UMBRELLA (sessions live there)
/// or the loose worktree path itself.
public struct WorktreeLocation: Equatable {
    public let cwd: String
    public let title: String

    public init(cwd: String, title: String) {
        self.cwd = cwd
        self.title = title
    }
}

/// First match wins: workspaces in snapshot order (any repo state on the
/// branch), then loose worktrees. nil = branch not checked out anywhere.
public func worktreeLocation(forBranch branch: String,
                             in snapshot: ProjectSnapshot) -> WorktreeLocation? {
    for workspace in snapshot.workspaces {
        if workspace.repos.contains(where: { $0.entry.branch == branch }) {
            return WorktreeLocation(cwd: workspace.umbrellaPath, title: workspace.name)
        }
    }
    for loose in snapshot.loose where loose.entry.branch == branch {
        return WorktreeLocation(cwd: loose.entry.path,
                                title: (loose.entry.path as NSString).lastPathComponent)
    }
    return nil
}
