import Foundation

// MARK: - Stacking: parent resolution (pure)

/// Picks the parent workspace among stacking candidates. Each candidate carries the
/// commit distance from the base branch to merge-base(child, candidate): the deepest
/// merge-base wins; on a depth tie the alphabetically first name wins.
/// Empty candidates -> nil (the workspace is forked straight from the base branch).
public func resolveParentName(candidates: [(name: String, depth: Int)]) -> String? {
    return candidates
        .sorted { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
            return lhs.name < rhs.name
        }
        .first?.name
}
