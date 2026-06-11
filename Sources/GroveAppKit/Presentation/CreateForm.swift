import Foundation
import GroveCore

/// Prefill for CreateWorkspaceSheet. Producers: WorkspacesScreen
/// ("+ Workspace" -> empty, "+ child workspace" -> forkFrom set) and, in
/// Task 21, GraphScreen ("create workspace from branch" -> branch = existing
/// branch name, base = that branch as a display hint). Identifiable so it can
/// drive `.panelOverlay(item:)` — every request carries a fresh id, which
/// reopens the sheet with clean @State.
public struct CreatePrefill: Identifiable {
    public let id = UUID()
    public var name: String
    /// nil -> the branch field live-previews from the project's branchTemplate.
    public var branch: String?
    public var forkFrom: FeatureWorkspace?
    /// Display-only base start point (graph prefill: the picked branch).
    /// The actual start point is resolved by WorkspaceService at create time.
    public var base: String?

    public init(name: String = "", branch: String? = nil,
                forkFrom: FeatureWorkspace? = nil, base: String? = nil) {
        self.name = name
        self.branch = branch
        self.forkFrom = forkFrom
        self.base = base
    }
}

/// nil = valid. Mirrors GroveCore's creation-time rule (^[A-Za-z0-9._-]+$)
/// so the user gets feedback before pressing Create, not after.
public func workspaceNameIssue(_ name: String) -> String? {
    if name.isEmpty { return "Enter a workspace name." }
    if name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) == nil {
        return "Only letters, digits, '.', '_' and '-' are allowed."
    }
    return nil
}

/// "{name}" substitution; the user can still override the result in the sheet.
public func branchPreview(template: String, name: String) -> String {
    template.replacingOccurrences(of: "{name}", with: name)
}

/// Best-effort DISPLAY of the start point creation will use for `repo`.
/// The authoritative resolution happens inside WorkspaceService.createWorkspace;
/// this mirrors it from scan data: fork-from workspace's branch in this repo
/// (falling through to the repo base when the parent does not include the
/// repo, spec §2) > explicit base hint > project baseBranchOverrides >
/// base branch seen by the scan > "main".
public func startPointCaption(repo: RepoInfo,
                              forkFrom: FeatureWorkspace?,
                              base: String?,
                              snapshot: ProjectSnapshot) -> String {
    if let forkFrom {
        if let branch = forkFrom.repos.first(where: { $0.repo.path == repo.path })?.entry.branch {
            return branch
        }
        // Parent lacks this repo -> fork from the repo's base.
    } else if let base {
        return base
    }
    if let override = snapshot.project.baseBranchOverrides[repo.dirName] {
        return override
    }
    for workspace in snapshot.workspaces {
        if let meta = workspace.repos.first(where: { $0.repo.path == repo.path })?.meta {
            return meta.baseBranch
        }
    }
    for loose in snapshot.loose where loose.repo.path == repo.path {
        if let meta = loose.meta { return meta.baseBranch }
    }
    return "main"
}
