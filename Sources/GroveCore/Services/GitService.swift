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

/// One entry of `git worktree list --porcelain`.
public struct WorktreeEntry: Sendable, Equatable {
    public let path: String
    public let branch: String?       // nil when detached
    public let head: String
    public let isMain: Bool

    public init(path: String, branch: String?, head: String, isMain: Bool) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isMain = isMain
    }
}

public struct GitService: Sendable {
    let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessRunner()) {
        self.runner = runner
    }

    /// Directory names that are never descended into and never reported as repos —
    /// and, for code stats, never counted (generated/vendored output). `.next` is the
    /// Next.js build dir; the rest cover node/dart/jvm build + dependency trees. These
    /// are the dirs git's `--exclude-standard` MISSES when an umbrella repo doesn't
    /// gitignore a nested project's build output (the acme.shop over-count).
    static let alwaysSkippedDirNames: Set<String> = [
        "node_modules", ".git", "build", "dist", "out", "target", ".dart_tool", ".worktrees", ".next",
    ]

    public func discoverRepos(projectPath: String, scanDepth: Int, excluded: Set<String>) async -> [RepoInfo] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: expandTilde(projectPath)).standardizedFileURL
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

    // MARK: - Worktree listing

    public func worktrees(repo: RepoInfo) async throws -> [WorktreeEntry] {
        let result = try await runner.runOK("git", ["-C", repo.path, "worktree", "list", "--porcelain"])
        return Self.parseWorktreePorcelain(result.stdout)
    }

    /// Porcelain format: blank-line-separated stanzas of
    /// `worktree <path>` / `HEAD <sha>` / (`branch refs/heads/<name>` | `detached`).
    /// `bare`, `locked`, `prunable` lines are ignored. The main worktree is listed first.
    static func parseWorktreePorcelain(_ output: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var path: String?
        var head: String?
        var branch: String?

        func flush() {
            if let path, let head {
                entries.append(WorktreeEntry(path: path, branch: branch, head: head, isMain: entries.isEmpty))
            }
            path = nil
            head = nil
            branch = nil
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                var name = String(line.dropFirst("branch ".count))
                if name.hasPrefix("refs/heads/") {
                    name = String(name.dropFirst("refs/heads/".count))
                }
                branch = name
            }
            // "detached", "bare", "locked", "prunable": no extra data needed.
        }
        flush()
        return entries
    }

    // MARK: - Branches

    public func baseBranch(repo: RepoInfo, override: String?) async -> String {
        if let override {
            return override
        }
        if let result = try? await runner.run(
            "git", ["-C", repo.path, "symbolic-ref", "refs/remotes/origin/HEAD"],
            cwd: nil, env: nil, timeout: 10
        ), result.exitCode == 0 {
            let ref = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "refs/remotes/origin/"
            if ref.hasPrefix(prefix), ref.count > prefix.count {
                return String(ref.dropFirst(prefix.count))
            }
        }
        for candidate in ["main", "master", "dev"] {
            if await branchExists(repoPath: repo.path, candidate) {
                return candidate
            }
        }
        return "main"
    }

    /// Returns the symbolic ref name of the currently checked-out branch
    /// (`git symbolic-ref --short HEAD`). Empty string on any git failure — a detached
    /// HEAD, a missing repo, or a timeout — so callers can cleanly fall back.
    public func currentBranch(repoPath: String) async -> String {
        guard let result = try? await runner.run(
            "git", ["-C", repoPath, "symbolic-ref", "--short", "HEAD"],
            cwd: nil, env: nil, timeout: 10
        ), result.exitCode == 0 else { return "" }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lists all local branches, sorted alphabetically.
    /// Uses `git for-each-ref refs/heads --format=%(refname:short)`.
    /// Returns an empty array on any git failure (degrades gracefully, never throws).
    public func localBranches(repoPath: String) async -> [String] {
        guard let result = try? await runner.run(
            "git", ["-C", repoPath, "for-each-ref", "refs/heads", "--format=%(refname:short)"],
            cwd: nil, env: nil, timeout: 10
        ), result.exitCode == 0 else { return [] }
        let names = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return names.sorted()
    }

    public func branchExists(repoPath: String, _ branch: String) async -> Bool {
        guard let result = try? await runner.run(
            "git", ["-C", repoPath, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"],
            cwd: nil, env: nil, timeout: 10
        ) else { return false }
        return result.exitCode == 0
    }

    // MARK: - Worktree mutations

    public func addWorktree(repoPath: String, branch: String, startPoint: String, at path: String, createBranch: Bool) async throws {
        var args = ["-C", repoPath, "worktree", "add"]
        if createBranch {
            args += ["-b", branch, path, startPoint]
        } else {
            // Branch already exists: check it out into the new worktree (no -b);
            // startPoint is not used. git itself rejects a branch that is already
            // checked out in another worktree -> runOK throws GroveError.processFailed.
            args += [path, branch]
        }
        _ = try await runner.runOK("git", args)
    }

    public func removeWorktree(repoPath: String, at path: String, force: Bool) async throws {
        var args = ["-C", repoPath, "worktree", "remove"]
        if force {
            args.append("--force")
        }
        args.append(path)
        _ = try await runner.runOK("git", args)
    }

    public func deleteBranch(repoPath: String, _ branch: String) async throws {
        _ = try await runner.runOK("git", ["-C", repoPath, "branch", "-D", branch])
    }
}

// MARK: - Stacking primitives

extension GitService {
    /// `git merge-base a b`; nil when either ref is unknown or histories are unrelated.
    public func mergeBase(repoPath: String, _ a: String, _ b: String) async -> String? {
        guard let result = try? await runner.runOK("git", ["-C", repoPath, "merge-base", a, b]) else {
            return nil
        }
        let hash = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }
}

// MARK: - Worktree meta model

public struct WorktreeMeta: Sendable, Equatable {
    public let baseBranch: String
    public let forkPoint: String?
    public let forkDate: Date?
    public let ahead: Int
    public let behind: Int
    public let dirtyCount: Int
    public let lastCommitDate: Date?
    public let lastCommitSubject: String?

    public init(baseBranch: String, forkPoint: String?, forkDate: Date?,
                ahead: Int, behind: Int, dirtyCount: Int,
                lastCommitDate: Date?, lastCommitSubject: String?) {
        self.baseBranch = baseBranch
        self.forkPoint = forkPoint
        self.forkDate = forkDate
        self.ahead = ahead
        self.behind = behind
        self.dirtyCount = dirtyCount
        self.lastCommitDate = lastCommitDate
        self.lastCommitSubject = lastCommitSubject
    }
}

// MARK: - Git ISO8601 date parsing (shared by meta and the commit graph)

let isoDatePlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

let isoDateWithFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Parses `%cI` output; tries both formatter variants (with/without fractional seconds).
func gitISODate(_ raw: String) -> Date? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }
    return isoDatePlain.date(from: s) ?? isoDateWithFractional.date(from: s)
}

/// Public ISO8601 parse shim forwarding to the package-internal `gitISODate`,
/// so cross-module callers (GroveAppKit's UsagePresentation) can parse the same
/// fractional/plain variants without exposing the internal name.
public func parseISODate(_ raw: String) -> Date? { gitISODate(raw) }

// MARK: - Worktree meta

extension GitService {
    /// Fork point, ahead/behind, dirty count and last-commit info for a worktree
    /// relative to `base`. Never throws: every probe degrades to zeros/nils.
    public func meta(repoPath: String, worktree: WorktreeEntry, relativeTo base: String) async -> WorktreeMeta {
        let rev = worktree.branch ?? worktree.head

        var forkPoint: String?
        var forkDate: Date?
        var ahead = 0
        var behind = 0
        var dirtyCount = 0
        var lastCommitDate: Date?
        var lastCommitSubject: String?

        if let result = try? await runner.runOK("git", ["-C", repoPath, "merge-base", base, rev]) {
            let mb = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !mb.isEmpty {
                forkPoint = mb
                if let dated = try? await runner.runOK("git", ["-C", repoPath, "log", "-1", "--format=%cI", mb]) {
                    forkDate = gitISODate(dated.stdout)
                }
            }
        }

        if let result = try? await runner.runOK("git", ["-C", repoPath, "rev-list", "--left-right", "--count", "\(base)...\(rev)"]) {
            // Output: "<commits only in base>\t<commits only in rev>" -> behind / ahead.
            let counts = result.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
            if counts.count >= 2 {
                behind = Int(counts[0]) ?? 0
                ahead = Int(counts[1]) ?? 0
            }
        }

        if let result = try? await runner.runOK("git", ["-C", worktree.path, "status", "--porcelain"]) {
            dirtyCount = result.stdout.split(separator: "\n").count
        }

        if let result = try? await runner.runOK("git", ["-C", repoPath, "log", "-1", "--format=%cI%x09%s", rev]) {
            let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let pieces = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if pieces.count == 2 {
                lastCommitDate = gitISODate(String(pieces[0]))
                lastCommitSubject = String(pieces[1])
            }
        }

        return WorktreeMeta(
            baseBranch: base,
            forkPoint: forkPoint,
            forkDate: forkDate,
            ahead: ahead,
            behind: behind,
            dirtyCount: dirtyCount,
            lastCommitDate: lastCommitDate,
            lastCommitSubject: lastCommitSubject
        )
    }
}

// MARK: - Stacking depth helper (used by WorkspaceService.scan)

extension GitService {
    /// Commit distance from `base` to `tip`: `git rev-list --count <base>..<tip>`.
    /// Ranks stacking-parent candidates (deeper merge-base wins).
    /// Returns nil when git fails (unknown ref, not a repo, timeout).
    func revListCount(repoPath: String, from base: String, to tip: String) async -> Int? {
        guard let result = try? await runner.run(
            "git", ["-C", repoPath, "rev-list", "--count", "\(base)..\(tip)"],
            cwd: nil, env: nil, timeout: 10
        ), result.exitCode == 0 else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Commit graph

/// One file's change in a commit. `additions`/`deletions` are -1 for a binary
/// file (git numstat prints "-" for both).
public struct CommitFileChange: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let additions: Int
    public let deletions: Int
    public var isBinary: Bool { additions < 0 || deletions < 0 }
    public init(path: String, additions: Int, deletions: Int) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
    }
}

extension GitService {
    /// The files changed in commit `sha` with +additions/−deletions, via
    /// `git show --numstat`. Loaded lazily when a commit is expanded.
    public func fileChanges(repoPath: String, sha: String) async throws -> [CommitFileChange] {
        let result = try await runner.runOK("git", [
            "-C", repoPath, "show", sha, "--numstat", "--format=",
        ])
        return Self.parseNumstat(result.stdout)
    }

    static func parseNumstat(_ output: String) -> [CommitFileChange] {
        var changes: [CommitFileChange] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = raw.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 3, !fields[2].isEmpty else { continue }
            changes.append(CommitFileChange(
                path: String(fields[2]),
                additions: Int(fields[0]) ?? -1,    // "-" → binary
                deletions: Int(fields[1]) ?? -1))
        }
        return changes
    }

    public func commitGraph(repoPath: String, limit: Int = 300, skip: Int = 0) async throws -> [CommitNode] {
        let result = try await runner.runOK("git", [
            "-C", repoPath,
            "log", "--all", "--topo-order",
            "-n", String(limit),
            "--skip", String(skip),
            "--format=%H%x09%P%x09%an%x09%cI%x09%D%x09%s",
        ])
        return layoutLanes(parseCommitLog(result.stdout))
    }
}
