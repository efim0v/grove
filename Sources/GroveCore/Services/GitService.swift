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
    /// Filesystem creation time (birthtime) of the worktree directory — the
    /// HONEST "when was this workspace made" signal. nil when the porcelain is
    /// parsed without a disk probe (pure parse) or the birthtime is unreadable.
    /// This is intentionally NOT derived from any commit/merge-base date: a fresh
    /// fork off a 15-day-stale base must read as "today", not as the base's age.
    public let createdAt: Date?

    public init(path: String, branch: String?, head: String, isMain: Bool,
                createdAt: Date? = nil) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isMain = isMain
        self.createdAt = createdAt
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
        // Stamp each entry with its directory's birthtime (the real workspace age
        // source). The porcelain parse stays pure/string-only; the disk probe lives
        // here so it's exercised only on the real listing path.
        return Self.parseWorktreePorcelain(result.stdout).map { entry in
            WorktreeEntry(path: entry.path, branch: entry.branch, head: entry.head,
                          isMain: entry.isMain,
                          createdAt: Self.directoryCreationDate(entry.path))
        }
    }

    /// Filesystem birthtime of a directory, used as the workspace's creation
    /// time. nil when unreadable (the badge then degrades to "unknown age").
    static func directoryCreationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
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
                let name = String(ref.dropFirst(prefix.count))
                // Return the REMOTE-TRACKING ref (origin/<name>), not the bare local
                // name. The local <name> is frequently stale (behind origin), which
                // made every comparison relative to it wrong: a fresh fork off the
                // current upstream counted its INHERITED commits as its own "ahead"
                // (the +95 bug). Comparing against origin/<name> measures the user's
                // real divergence from the upstream they actually forked from. Falls
                // through to the offline (bare-name) path when the remote ref is
                // absent (no fetch / no remote), preserving offline behavior.
                if await refExists(repoPath: repo.path, "refs/remotes/origin/\(name)") {
                    return await integrationBranch(repoPath: repo.path, over: "origin/\(name)")
                }
                return await integrationBranch(repoPath: repo.path, over: name)
            }
        }
        for candidate in ["main", "master", "dev"] {
            if await branchExists(repoPath: repo.path, candidate) {
                return await integrationBranch(repoPath: repo.path, over: candidate)
            }
        }
        return "main"
    }

    /// Gitflow: `origin/HEAD` names the RELEASE branch (master/main) while the work
    /// forks from `dev`/`develop`, hundreds of commits ahead of it. Measured against
    /// master every feature branch here was "+180 ahead" and every merge-base between
    /// two of them lay off base — so three siblings forked from dev rendered as a
    /// staircase. When an integration branch exists AND strictly contains the
    /// release branch, it is the base; remote-tracking first, for the same reason
    /// `origin/<name>` beats the local name above. A stale `dev` behind main stays
    /// out of the way.
    func integrationBranch(repoPath: String, over release: String) async -> String {
        for name in ["dev", "develop"] {
            for candidate in ["origin/\(name)", name] {
                guard await refExists(repoPath: repoPath, candidate),
                      candidate != release,
                      await isAncestor(repoPath: repoPath, release, of: candidate),
                      !(await isAncestor(repoPath: repoPath, candidate, of: release))
                else { continue }
                return candidate
            }
        }
        return release
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

    /// Existence of ANY resolvable ref — local branch, remote-tracking ref
    /// (`origin/main`), tag, or sha. Unlike `branchExists` (which hard-scopes to
    /// `refs/heads/`), this validates whatever `baseBranch()` returns now that the
    /// base can be a remote-tracking ref. Used where a base ref is checked before
    /// being fed to a range/log.
    public func refExists(repoPath: String, _ ref: String) async -> Bool {
        guard let result = try? await runner.run(
            "git", ["-C", repoPath, "rev-parse", "--verify", "--quiet", ref],
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
    /// `git merge-base --is-ancestor ancestor descendant`: true when `descendant`
    /// contains `ancestor`. False on any git failure (unknown ref, timeout).
    public func isAncestor(repoPath: String, _ ancestor: String, of descendant: String) async -> Bool {
        guard let result = try? await runner.run(
            "git", ["-C", repoPath, "merge-base", "--is-ancestor", ancestor, descendant],
            cwd: nil, env: nil, timeout: 10
        ) else { return false }
        return result.exitCode == 0
    }

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

/// Parses `%cI` / transcript ISO8601 output. Tries a fast integer parser first (the
/// common `YYYY-MM-DDTHH:MM:SS[.frac][Z|±HH[:MM]]` shapes), then falls back to the
/// formatter variants for anything unusual. The formatter path is ~90µs/call, so a
/// cold usage scan of 200k+ transcript records cost ~18s on it alone (the Daily-Usage
/// stall); the fast path is ~0.3µs and handles essentially all real timestamps.
func gitISODate(_ raw: String) -> Date? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }
    if let fast = fastISO8601(s) { return fast }
    return isoDatePlain.date(from: s) ?? isoDateWithFractional.date(from: s)
}

/// Fast, allocation-light ISO8601 parser for `YYYY-MM-DDTHH:MM:SS[.fraction][Z|±HH[:MM]]`.
/// Pure integer math via Howard Hinnant's civil-days algorithm — no ISO8601DateFormatter.
/// Returns nil for any shape it doesn't FULLY recognize (and rejects invalid dates the
/// same way the formatter would, e.g. Feb 30), so `gitISODate` falls back to the
/// formatters and exotic inputs keep their exact previous behavior.
func fastISO8601(_ s: String) -> Date? {
    var s = s
    // withUTF8 hands us a contiguous byte buffer with no Swift-array allocation and no
    // per-subscript ARC — this is the hot path (200k+ records per cold usage scan).
    return s.withUTF8 { fastISO8601(bytes: $0) }
}

private func fastISO8601(bytes b: UnsafeBufferPointer<UInt8>) -> Date? {
    let n = b.count
    guard n >= 19 else { return nil }                       // "YYYY-MM-DDTHH:MM:SS"
    @inline(__always) func num(_ i: Int, _ len: Int) -> Int? {
        var v = 0
        for k in i..<(i + len) {
            let c = b[k]
            guard c >= 0x30, c <= 0x39 else { return nil }  // ASCII digit
            v = v * 10 + Int(c - 0x30)
        }
        return v
    }
    guard
        let year = num(0, 4), b[4] == 0x2D,                 // '-'
        let month = num(5, 2), b[7] == 0x2D,
        let day = num(8, 2),
        b[10] == 0x54 || b[10] == 0x74 || b[10] == 0x20,    // 'T' / 't' / ' '
        let hour = num(11, 2), b[13] == 0x3A,               // ':'
        let minute = num(14, 2), b[16] == 0x3A,
        let second = num(17, 2)
    else { return nil }

    var idx = 19
    var frac = 0.0
    if idx < n, b[idx] == 0x2E {                            // '.fraction'
        idx += 1
        var scale = 0.1
        var any = false
        while idx < n, b[idx] >= 0x30, b[idx] <= 0x39 {
            frac += Double(b[idx] - 0x30) * scale
            scale /= 10
            idx += 1
            any = true
        }
        guard any else { return nil }
    }

    var offset = 0
    if idx < n {
        let c = b[idx]
        if c == 0x5A || c == 0x7A {                          // 'Z' / 'z'
            idx += 1
        } else if c == 0x2B || c == 0x2D {                   // '+' / '-'
            let sign = (c == 0x2D) ? -1 : 1
            idx += 1
            guard let oh = num(idx, 2) else { return nil }
            idx += 2
            if idx < n, b[idx] == 0x3A { idx += 1 }          // optional ':'
            var om = 0
            if idx + 1 < n, let m = num(idx, 2) { om = m; idx += 2 }
            offset = sign * (oh * 3600 + om * 60)
        } else {
            return nil
        }
    }
    guard idx == n else { return nil }                       // no trailing garbage

    guard month >= 1, month <= 12, hour <= 23, minute <= 59, second <= 59 else { return nil }
    let leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
    let daysInMonth = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    guard day >= 1, day <= daysInMonth else { return nil }

    // Days since the Unix epoch (1970-01-01), Hinnant's days_from_civil.
    var y = year
    if month <= 2 { y -= 1 }
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = (month + 9) % 12
    let doy = (153 * mp + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146097 + doe - 719468
    let secs = Double(days * 86400 + hour * 3600 + minute * 60 + second - offset) + frac
    return Date(timeIntervalSince1970: secs)
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
        // `--first-parent -m`: on a MERGE commit, plain `git show --numstat` prints a
        // COMBINED diff that omits every file matching one parent — so the file list
        // and totals come up short. `-m` diffs against each parent; `--first-parent`
        // restricts that to the first parent, giving the changes the merge introduced.
        // For a non-merge commit both flags are no-ops (output is byte-identical).
        let result = try await runner.runOK("git", [
            "-C", repoPath, "show", sha, "--first-parent", "-m", "--numstat", "--format=",
        ])
        return Self.parseNumstat(result.stdout)
    }

    static func parseNumstat(_ output: String) -> [CommitFileChange] {
        var changes: [CommitFileChange] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = raw.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 3, !fields[2].isEmpty else { continue }
            changes.append(CommitFileChange(
                path: renamedNewPath(String(fields[2])),
                additions: Int(fields[0]) ?? -1,    // "-" → binary
                deletions: Int(fields[1]) ?? -1))
        }
        return changes
    }

    /// `git --numstat` renders renames two ways: with a common prefix the change is
    /// embedded in braces (`Sources/{A.swift => B.swift}`, `{old => new}/file`), and
    /// with NO common prefix it's the bare `old/path => new/path` (no braces).
    /// Collapse either to the NEW path so the file list reads like a git UI; a path
    /// without `=>` is returned unchanged.
    static func renamedNewPath(_ path: String) -> String {
        if let open = path.range(of: "{"),
           let arrow = path.range(of: " => ", range: open.upperBound..<path.endIndex),
           let close = path.range(of: "}", range: arrow.upperBound..<path.endIndex) {
            let newSegment = path[arrow.upperBound..<close.lowerBound]
            return path.replacingCharacters(in: open.lowerBound..<close.upperBound, with: newSegment)
        }
        // Whole-path rename, no common prefix: `old => new` → the part after " => ".
        if let arrow = path.range(of: " => ") {
            return String(path[arrow.upperBound...])
        }
        return path
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
