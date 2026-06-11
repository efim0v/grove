import Foundation
import GroveCore

/// One row of the settings base-branch-overrides editor. repoPath is nil when
/// the row comes from an override key the scan does not know (no snapshot yet,
/// or a stale/excluded dir name) — those rows degrade to a text field because
/// there is no repo to list branches for.
public struct OverrideEditorRow: Equatable, Identifiable {
    public var id: String { dirName }
    public let dirName: String
    public let repoPath: String?

    public init(dirName: String, repoPath: String?) {
        self.dirName = dirName
        self.repoPath = repoPath
    }
}

/// Rows for the per-project base-branch-overrides editor, sorted by dirName:
/// every repo of the scan snapshot, plus any override keys without a matching
/// repo (kept visible so stale entries can still be removed). With no
/// snapshot at all, the dict keys are the only rows.
public func overrideEditorRows(snapshot: ProjectSnapshot?,
                               overrides: [String: String]) -> [OverrideEditorRow] {
    let repos = snapshot?.repos ?? []
    let known = Set(repos.map(\.dirName))
    let repoRows = repos.map { OverrideEditorRow(dirName: $0.dirName, repoPath: $0.path) }
    let orphanRows = overrides.keys
        .filter { !known.contains($0) }
        .map { OverrideEditorRow(dirName: $0, repoPath: nil) }
    return (repoRows + orphanRows).sorted { $0.dirName < $1.dirName }
}
