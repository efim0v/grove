import Foundation

/// A git repository discovered inside a project directory.
public struct RepoInfo: Sendable, Hashable {
    public let path: String
    public let dirName: String

    public init(path: String, dirName: String) {
        self.path = path
        self.dirName = dirName
    }
}

public struct GitService: Sendable {
    let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessRunner()) {
        self.runner = runner
    }

    /// Directory names that are never descended into and never reported as repos.
    static let alwaysSkippedDirNames: Set<String> = [
        "node_modules", ".git", "build", "dist", "out", "target", ".dart_tool", ".worktrees",
    ]

    public func discoverRepos(projectPath: String, scanDepth: Int, excluded: Set<String>) async -> [RepoInfo] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: expandTilde(projectPath))
        var found: [RepoInfo] = []
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var nextIndex = 0

        while nextIndex < queue.count {
            let (dir, depth) = queue[nextIndex]
            nextIndex += 1

            if hasGitDirectory(dir, fm) {
                found.append(RepoInfo(path: dir.path, dirName: dir.lastPathComponent))
            }
            guard depth < scanDepth else { continue }

            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names {
                if name.hasPrefix(".") { continue }
                if Self.alwaysSkippedDirNames.contains(name) { continue }
                let child = dir.appendingPathComponent(name)
                if excluded.contains(name) || excluded.contains(child.path) { continue }
                // Only descend into real directories, not symlinks.
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: child.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                // Exclude symlinked directories.
                guard (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { continue }
                queue.append((child, depth + 1))
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// A directory is a project repo iff `<dir>/.git` is a DIRECTORY.
    /// Worktree checkouts have a `.git` FILE and are not project repos.
    private func hasGitDirectory(_ dir: URL, _ fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        let gitPath = dir.appendingPathComponent(".git").path
        return fm.fileExists(atPath: gitPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
