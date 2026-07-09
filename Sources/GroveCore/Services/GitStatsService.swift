import Foundation

// MARK: - Result value types

/// Net-lines-on-a-day point for one repo's default-branch history (CUMULATIVE).
/// `date` is start-of-day in GMT; `netLines` is the running sum of
/// (additions − deletions) over all commits up to and including that day.
public struct RepoHistoryPoint: Sendable, Equatable, Codable {
    public let date: Date          // start-of-day (GMT) midnight
    public let netLines: Int       // cumulative (additions - deletions) through this day
    public let dayAdded: Int       // additions committed ON this day (point-in-day, not cumulative)
    public let dayRemoved: Int     // deletions committed ON this day (point-in-day, not cumulative)
    /// That day's additions/removals classified by language group: `code*` are non-data
    /// languages (and any path with no known language — see `parseLog`); `data*` are the
    /// Data/Prose languages (Markdown/JSON/YAML/TOML). `codeAdded + dataAdded == dayAdded`
    /// and `codeRemoved + dataRemoved == dayRemoved` (the totals are kept whole for the
    /// churn bars, the split feeds the honest Code/Data delta triangles).
    public let codeAdded: Int
    public let codeRemoved: Int
    public let dataAdded: Int
    public let dataRemoved: Int
    /// `dayAdded`/`dayRemoved` and the classified fields default to 0 so existing call
    /// sites and Codable decodes of pre-existing JSON (which lack these keys) keep working.
    public init(date: Date, netLines: Int, dayAdded: Int = 0, dayRemoved: Int = 0,
                codeAdded: Int = 0, codeRemoved: Int = 0,
                dataAdded: Int = 0, dataRemoved: Int = 0) {
        self.date = date
        self.netLines = netLines
        self.dayAdded = dayAdded
        self.dayRemoved = dayRemoved
        self.codeAdded = codeAdded
        self.codeRemoved = codeRemoved
        self.dataAdded = dataAdded
        self.dataRemoved = dataRemoved
    }

    // Custom decode so older persisted JSON (no dayAdded/dayRemoved/classified keys)
    // still loads, defaulting the missing per-day fields to 0.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.date = try c.decode(Date.self, forKey: .date)
        self.netLines = try c.decode(Int.self, forKey: .netLines)
        self.dayAdded = try c.decodeIfPresent(Int.self, forKey: .dayAdded) ?? 0
        self.dayRemoved = try c.decodeIfPresent(Int.self, forKey: .dayRemoved) ?? 0
        self.codeAdded = try c.decodeIfPresent(Int.self, forKey: .codeAdded) ?? 0
        self.codeRemoved = try c.decodeIfPresent(Int.self, forKey: .codeRemoved) ?? 0
        self.dataAdded = try c.decodeIfPresent(Int.self, forKey: .dataAdded) ?? 0
        self.dataRemoved = try c.decodeIfPresent(Int.self, forKey: .dataRemoved) ?? 0
    }
}

/// Added/removed/net + file-count delta over a time window for one repo (or, when
/// summed, a whole project). `net` is a derived convenience.
public struct RepoDelta: Sendable, Equatable, Codable {
    public let added: Int
    public let removed: Int
    public let filesChanged: Int
    public var net: Int { added - removed }
    public init(added: Int, removed: Int, filesChanged: Int) {
        self.added = added
        self.removed = removed
        self.filesChanged = filesChanged
    }
    public static let zero = RepoDelta(added: 0, removed: 0, filesChanged: 0)
}

/// Added/removed over a window, partitioned by language group: `code*` are non-data
/// languages (plus unknown-extension paths), `data*` are Data/Prose
/// (Markdown/JSON/YAML/TOML). `codeAdded + dataAdded` equals the matching `RepoDelta`
/// total. Powers the honest two-triangle (▲added / ▼removed) Code and Data headlines.
public struct LanguageSplitDelta: Sendable, Equatable, Codable {
    public let codeAdded: Int
    public let codeRemoved: Int
    public let dataAdded: Int
    public let dataRemoved: Int
    public init(codeAdded: Int, codeRemoved: Int, dataAdded: Int, dataRemoved: Int) {
        self.codeAdded = codeAdded
        self.codeRemoved = codeRemoved
        self.dataAdded = dataAdded
        self.dataRemoved = dataRemoved
    }
    public static let zero = LanguageSplitDelta(codeAdded: 0, codeRemoved: 0, dataAdded: 0, dataRemoved: 0)
}

/// One counted file in a scan, carrying its PROJECT-root-relative path and its
/// classified line total. This is the lightweight per-file list that feeds the
/// settings-page directory+file tree; it is summed/grouped purely in the UI layer.
/// `lines` is the file's total classified lines (code+comment+blank), matching the
/// per-language totals so a sum over the NON-excluded `files` equals the aggregate's
/// `totalLines`.
///
/// A file under a user-excluded folder (`excludedFolders`) is STILL emitted, with
/// `isExcluded == true`, and is kept OUT of the `CodeStats` totals — so the
/// settings tree can still render the excluded folder (and its re-include toggle)
/// while the headline numbers shrink. Files dropped by `.ignorestats` are NOT
/// emitted at all (that exclusion is file-driven config, not UI-toggleable).
public struct StatFileEntry: Sendable, Equatable, Identifiable {
    public let path: String           // project-root-relative (e.g. "nested/r2/a.swift")
    public let lines: Int             // total classified lines (code + comment + blank)
    public let language: String
    public let isDataProse: Bool
    /// True when this file lives under a user-excluded folder: present in the list
    /// (so the tree can show/un-exclude the folder) but excluded from the totals.
    public let isExcluded: Bool
    public var id: String { path }

    public init(path: String, lines: Int, language: String, isDataProse: Bool,
                isExcluded: Bool = false) {
        self.path = path
        self.lines = lines
        self.language = language
        self.isDataProse = isDataProse
        self.isExcluded = isExcluded
    }
}

/// Full per-repo result: current LOC (reuses the existing `CodeStats` shape),
/// per-day cumulative history, and a period delta.
public struct RepoStats: Sendable, Equatable {
    public let repoPath: String        // absolute, standardized
    public let repoName: String        // leaf directory name
    public let defaultBranch: String
    public let stats: CodeStats        // REUSED: current LOC, byLanguage, totals
    public let history: [RepoHistoryPoint]   // per-day cumulative net lines, oldest first
    public let delta: RepoDelta              // over the requested period
    public let files: [StatFileEntry]        // this repo's counted files (project-relative paths)
    public init(repoPath: String, repoName: String, defaultBranch: String,
                stats: CodeStats, history: [RepoHistoryPoint], delta: RepoDelta,
                files: [StatFileEntry] = []) {
        self.repoPath = repoPath
        self.repoName = repoName
        self.defaultBranch = defaultBranch
        self.stats = stats
        self.history = history
        self.delta = delta
        self.files = files
    }
}

/// Aggregate across every git repo in a project + the per-repo breakdown.
/// `aggregate` and `aggregateHistory` reuse the existing `CodeStats` /
/// `CodeStatsPoint` shapes so the existing `CodeStatsScreen` renders them with
/// zero view changes.
public struct ProjectGitStats: Sendable, Equatable {
    public let repos: [RepoStats]            // sorted by repoPath
    public let aggregate: CodeStats          // summed current LOC across repos
    public let aggregateHistory: [CodeStatsPoint]  // summed-per-day series (growth chart)
    public let aggregateDelta: RepoDelta     // summed delta across repos
    public let scannedAt: Date
    public let files: [StatFileEntry]        // every counted file across repos, project-relative, sorted by path
    public init(repos: [RepoStats], aggregate: CodeStats,
                aggregateHistory: [CodeStatsPoint], aggregateDelta: RepoDelta, scannedAt: Date,
                files: [StatFileEntry] = []) {
        self.repos = repos
        self.aggregate = aggregate
        self.aggregateHistory = aggregateHistory
        self.aggregateDelta = aggregateDelta
        self.scannedAt = scannedAt
        self.files = files
    }
}

// MARK: - Per-repo file cache

/// One classified file in the per-repo cache. Mirrors `CodeStatsScanner.CachedFile`:
/// a file is reused (not re-read/re-classified) when its mtime AND size still match.
public struct CachedClassified: Sendable, Equatable {
    public let mtime: Date
    public let size: Int
    public let language: String
    public let classification: FileClassification
    public init(mtime: Date, size: Int, language: String, classification: FileClassification) {
        self.mtime = mtime
        self.size = size
        self.language = language
        self.classification = classification
    }
}

/// Per-repo classification cache. Invalidated wholesale when `head` changes (a
/// checkout/branch switch makes the path→content mapping untrustworthy); within a
/// stable HEAD, individual files are reused on an mtime+size match.
/// `scanKey` captures the scan anchor (scan path + optional committed ref) so that
/// switching the branch dropdown (which may not move repo.path's HEAD) still busts
/// the cache and re-reads from the correct worktree or committed tree.
public struct RepoFileCache: Sendable, Equatable {
    public var head: String                       // HEAD sha at last scan ("" for empty repo)
    public var files: [String: CachedClassified]  // keyed by ABSOLUTE path
    /// Opaque key that encodes the scan anchor (scan path ± committed ref). When the
    /// key changes the entire file cache is discarded, even if `head` hasn't moved.
    public var scanKey: String
    public init(head: String = "", files: [String: CachedClassified] = [:], scanKey: String = "") {
        self.head = head
        self.files = files
        self.scanKey = scanKey
    }
}

// MARK: - Service

/// Git-as-source-of-truth code statistics. Per repo it computes:
///  - current LOC from `git ls-files --cached --others --exclude-standard -z`
///    (tracked + untracked-but-not-ignored, using git's OWN ignore engine), each
///    file classified with the shared `CodeStatsEngine`;
///  - cumulative per-day history and a period delta from `git log --numstat` on the
///    repo's default branch.
/// It is a `Sendable` value type with no mutable state (caches live on the caller),
/// so it is safe to capture into `Task.detached` and run entirely off the main actor.
public struct GitStatsService: Sendable {
    let runner: any CommandRunning
    let git: GitService

    public init(runner: any CommandRunning = ProcessRunner()) {
        self.runner = runner
        self.git = GitService(runner: runner)
    }

    /// 30-day default window for deltas.
    public static let defaultPeriod: TimeInterval = 30 * 24 * 3600

    // MARK: Public entry point

    /// Full scan for a project: discover repos, classify current LOC, build per-day
    /// history + a period delta per repo, then aggregate. Never throws — every git
    /// failure degrades to empty/zero for that repo (matching the GitService style).
    /// `cache` is an inout per-repo file cache keyed by repo path; it is updated in
    /// place so the caller can persist it across scans.
    public func scan(
        projectPath: String,
        scanDepth: Int,
        excludedRepos: Set<String>,
        excludedFolders: Set<String> = [],
        branchOverrides: [String: String] = [:],
        period: TimeInterval = GitStatsService.defaultPeriod,
        now: Date = Date(),
        cache: inout [String: RepoFileCache]
    ) async -> ProjectGitStats {
        let repos = await reposToScan(projectPath: projectPath, scanDepth: scanDepth,
                                      excluded: excludedRepos)
        var repoStats: [RepoStats] = []
        for repo in repos {
            var repoCache = cache[repo.path] ?? RepoFileCache()

            // Effective branch: a user override wins ONLY if it's a real local ref;
            // otherwise fall back to the auto-detected default. RepoStats carries the
            // branch actually used so the UI shows the real selection.
            var branch = await resolveBranch(repo: repo)
            if let override = branchOverrides[repo.path],
               await git.branchExists(repoPath: repo.path, override) {
                branch = override
            }

            // Resolve the LOC scan anchor for this branch:
            //   - If the branch is checked out in a linked worktree → working-tree mode
            //     anchored at that worktree's path.
            //   - If the branch matches the main checkout's current branch (or no override
            //     was applied) → working-tree mode at repo.path (existing behavior).
            //   - Otherwise (branch exists locally but is NOT checked out anywhere)
            //     → committed-tree mode: enumerate files from `git ls-tree -r <branch>`.
            let wts = (try? await git.worktrees(repo: repo)) ?? []
            let effectiveScanPath: String
            let committedRef: String?
            if let matchingWt = wts.first(where: { wt in
                guard let wtBranch = wt.branch else { return false }
                // parseWorktreePorcelain already strips refs/heads/, so direct compare.
                return wtBranch == branch
            }) {
                // Branch is checked out in a worktree (could be the main one or a linked one).
                effectiveScanPath = matchingWt.path
                committedRef = nil
            } else if branchOverrides[repo.path] == nil {
                // No override: use repo.path (the existing default working-tree scan).
                effectiveScanPath = repo.path
                committedRef = nil
            } else {
                // Branch exists locally but is not checked out in any worktree.
                effectiveScanPath = repo.path
                committedRef = branch
            }

            let (stats, updated, files) = committedRef != nil
                ? await currentLOCCommitted(
                    repo: repo, projectPath: projectPath, excludedFolders: excludedFolders,
                    branch: committedRef!, now: now, cache: repoCache)
                : await currentLOC(
                    repo: repo, scanPath: effectiveScanPath,
                    projectPath: projectPath, excludedFolders: excludedFolders,
                    now: now, cache: repoCache)
            repoCache = updated
            cache[repo.path] = repoCache

            let (history, delta) = await history(repo: repo, branch: branch,
                                                 period: period, now: now)
            repoStats.append(RepoStats(
                repoPath: repo.path, repoName: repo.dirName, defaultBranch: branch,
                stats: stats, history: history, delta: delta, files: files))
        }
        repoStats.sort { $0.repoPath < $1.repoPath }
        return Self.aggregate(repoStats, now: now)
    }

    // MARK: Repo discovery + worktree exclusion

    /// Discovers the project's git repos and drops every worktree checkout.
    /// `discoverRepos` already excludes `.worktrees`/`node_modules`/`build`/… and
    /// reports only dirs whose `.git` is a DIRECTORY (worktree checkouts have a `.git`
    /// FILE, so they are already filtered). The belt-and-suspenders pass below also
    /// removes any repo registered as a non-main worktree of another discovered repo,
    /// guarding manually-nested layouts outside a `.worktrees/` dir.
    func reposToScan(projectPath: String, scanDepth: Int, excluded: Set<String>) async -> [RepoInfo] {
        let repos = await git.discoverRepos(projectPath: projectPath, scanDepth: scanDepth,
                                            excluded: excluded)
        // Collect every registered non-main worktree path across all discovered repos.
        var worktreePaths: Set<String> = []
        for repo in repos {
            guard let entries = try? await git.worktrees(repo: repo) else { continue }
            for entry in entries where !entry.isMain {
                worktreePaths.insert(Self.standardize(entry.path))
            }
        }
        let afterWorktrees = worktreePaths.isEmpty
            ? repos
            : repos.filter { !worktreePaths.contains(Self.standardize($0.path)) }
        return Self.dropUmbrellaAncestors(afterWorktrees)
    }

    /// Drops any discovered repo whose path is a strict ANCESTOR (parent directory) of
    /// another discovered repo's path. An "umbrella" repo (e.g. a `acme.shop`
    /// monorepo that has its OWN `.git` but merely CONTAINS the three real product repos)
    /// would otherwise be scanned as a fourth repo, double-counting the nested trees and
    /// mixing unrelated histories. Paths are symlink-standardized first so the prefix
    /// test compares apples to apples. A repo nested at the same path as another is never
    /// considered its own ancestor (strict prefix with a trailing "/").
    static func dropUmbrellaAncestors(_ repos: [RepoInfo]) -> [RepoInfo] {
        let standardized = repos.map { ($0, standardize($0.path)) }
        return standardized.filter { repo, path in
            !standardized.contains { other, otherPath in
                otherPath != path && otherPath.hasPrefix(path + "/")
            }
        }.map(\.0)
    }

    /// git emits symlink-resolved paths (/private/var/… on macOS); standardize both
    /// sides so the worktree filter compares apples to apples.
    static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: Current LOC

    /// Classifies the repo's current file set (tracked + untracked-not-ignored).
    /// Returns the `CodeStats`, the UPDATED per-repo cache, and the per-file list
    /// (project-relative paths). Degrades to empty stats (but a populated/cleared
    /// cache, empty file list) on any git failure.
    ///
    /// `scanPath` is the filesystem anchor for the file listing and disk reads; it
    /// defaults to `repo.path` (the existing behavior) but can be a linked worktree
    /// path when the chosen branch is checked out there. The `repo` parameter
    /// continues to provide the canonical repo root for prefix computation and
    /// git plumbing commands.
    ///
    /// `excludedFolders` are PROJECT-root-relative folder paths; a file whose
    /// project-relative path equals or is nested under one of them is kept OUT of the
    /// count but is STILL emitted in the file list with `isExcluded == true`, so the
    /// settings tree can render the excluded folder and its re-include toggle. A
    /// repo-local `.ignorestats` file (same syntax as `.gitignore`, parsed by the
    /// shared `GitignoreRules`/`GitignoreScope`) provides further per-path excludes
    /// evaluated against repo-relative paths; those matches are dropped ENTIRELY
    /// (not emitted), since that exclusion is file-driven config, not UI-toggleable.
    func currentLOC(repo: RepoInfo, scanPath: String? = nil,
                    projectPath: String, excludedFolders: Set<String>,
                    now: Date, cache: RepoFileCache)
        async -> (CodeStats, RepoFileCache, [StatFileEntry]) {
        let anchor = scanPath ?? repo.path
        // The scan key encodes the working-tree anchor. If it changes (e.g. the UI
        // switched the branch dropdown to a different worktree) we must discard the
        // cached file classifications — even if repo.path's HEAD hasn't moved.
        let newScanKey = "wt:\(anchor)"
        let head = await self.headAt(path: anchor)
        // A changed HEAD OR changed scan anchor invalidates the whole cache.
        var reuse = cache.files
        if cache.head != head || cache.scanKey != newScanKey { reuse = [:] }

        guard let result = try? await runner.runOK(
            "git", ["-C", anchor, "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            timeout: 60
        ) else {
            return (Self.emptyStats(now: now), RepoFileCache(head: head, files: [:], scanKey: newScanKey), [])
        }

        let relPaths = Self.parseLsFilesZ(result.stdout)
        let fm = FileManager.default
        let base = URL(fileURLWithPath: anchor, isDirectory: true)

        // The project-relative prefix for this repo (e.g. "nested/r2"), used to map each
        // repo-relative file path into a project-relative one for the file list and the
        // folder-exclusion check. "" when the repo IS the project root.
        let prefix = Self.projectRelativePrefix(repoPath: repo.path, projectPath: projectPath)

        // Build a `.ignorestats` scope from every `.ignorestats` checked into the repo's
        // working tree (they appear in `ls-files --others` output). Each file's parent
        // dir becomes a frame keyed repo-relative, so a candidate's repo-relative path is
        // matched against the nearest enclosing `.ignorestats` (deepest-first), reusing
        // the exact gitignore precedence the matcher already implements.
        let ignoreScope = Self.buildIgnoreStatsScope(relPaths: relPaths, base: base)

        // Accumulators keyed by language name.
        struct Acc { var files = 0; var code = 0; var comment = 0; var blank = 0 }
        var byLang: [String: Acc] = [:]
        var skippedBinary = 0
        var nextFiles: [String: CachedClassified] = [:]
        var filesForResult: [StatFileEntry] = []

        for rel in relPaths {
            // Drop anything under a generated/vendored infrastructure dir (node_modules,
            // build, dist, out, .next, .dart_tool, target, .worktrees, .git). git's
            // `--exclude-standard` MISSES these when an umbrella repo doesn't gitignore a
            // nested project's build output — without this, an untracked node_modules /
            // .next tree balloons the count by orders of magnitude (the acme.shop
            // outer repo: 27k "files" → ~950 real source files).
            if rel.split(separator: "/").contains(where: { GitService.alwaysSkippedDirNames.contains(String($0)) }) {
                continue
            }
            guard let lang = CodeStatsEngine.language(forPath: rel) else { continue }

            // Project-relative path: repo's project-relative prefix + repo-relative file.
            let projectRel = prefix.isEmpty ? rel : prefix + "/" + rel

            // `.ignorestats` exclusion: evaluate the repo-relative path (the scope's
            // frames are keyed repo-relative). These are file-driven config (not
            // UI-toggleable), so a match drops the file ENTIRELY — never emitted.
            if ignoreScope.isIgnored(path: rel, isDirectory: false) {
                continue
            }
            // Folder-exclusion (user toggle): equals an excluded folder or is nested
            // under one. Unlike `.ignorestats`, we still EMIT the file (flagged
            // `isExcluded`) so the settings tree retains the folder + its re-include
            // toggle; it is just kept out of the byLanguage/CodeStats totals below.
            let isExcluded = excludedFolders.contains {
                projectRel == $0 || projectRel.hasPrefix($0 + "/")
            }

            let absURL = base.appendingPathComponent(rel)
            let absPath = absURL.path

            // Attributes for the mtime+size cache gate.
            guard let attrs = try? fm.attributesOfItem(atPath: absPath) else { continue }
            let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            let size = (attrs[.size] as? Int) ?? -1

            let classification: FileClassification
            if let cached = reuse[absPath], cached.mtime == mtime, cached.size == size {
                classification = cached.classification
            } else {
                guard let data = try? Data(contentsOf: absURL) else { continue }
                if CodeStatsEngine.isLikelyBinary(data) {
                    skippedBinary += 1
                    continue
                }
                classification = CodeStatsEngine.classify(
                    contents: String(decoding: data, as: UTF8.self), language: lang)
            }

            // Always emit the file (so the tree can show it); excluded files carry the
            // flag and are kept out of the language/CodeStats totals.
            filesForResult.append(StatFileEntry(
                path: projectRel,
                lines: classification.code + classification.comment + classification.blank,
                language: lang.name,
                isDataProse: CodeStatsEngine.isDataProse(lang.name),
                isExcluded: isExcluded))
            if isExcluded { continue }

            nextFiles[absPath] = CachedClassified(
                mtime: mtime, size: size, language: lang.name, classification: classification)
            var acc = byLang[lang.name] ?? Acc()
            acc.files += 1
            acc.code += classification.code
            acc.comment += classification.comment
            acc.blank += classification.blank
            byLang[lang.name] = acc
        }

        let byLanguage = byLang.map { name, acc in
            LanguageStats(language: name, files: acc.files, code: acc.code,
                          comment: acc.comment, blank: acc.blank,
                          total: acc.code + acc.comment + acc.blank)
        }.sorted { $0.code > $1.code }

        let totalFiles = byLanguage.reduce(0) { $0 + $1.files }
        let code = byLanguage.reduce(0) { $0 + $1.code }
        let comment = byLanguage.reduce(0) { $0 + $1.comment }
        let blank = byLanguage.reduce(0) { $0 + $1.blank }
        let stats = CodeStats(totalFiles: totalFiles, totalLines: code + comment + blank,
                              code: code, comment: comment, blank: blank,
                              byLanguage: byLanguage, scannedAt: now, skippedBinary: skippedBinary)
        return (stats, RepoFileCache(head: head, files: nextFiles, scanKey: newScanKey), filesForResult)
    }

    // MARK: Committed-tree LOC (branch not checked out in any worktree)

    /// Classifies the file set from a branch's COMMITTED tree (via `git ls-tree -r`)
    /// when that branch is not checked out in any worktree. Content is read via
    /// `git cat-file blob` so no working-tree files are touched. The same skip-dirs,
    /// `.ignorestats`, folder-exclusion, and `CodeStatsEngine` classification rules
    /// apply as in the working-tree scan, ensuring the counts are comparable.
    ///
    /// Cache: keyed by the branch's committed-tree SHA (resolved once via
    /// `git rev-parse <branch>^{tree}`). A changed tree SHA busts per-file reuse.
    /// The cache files are keyed by `<branch>/<relPath>` (a synthetic "abs path"
    /// unique within this mode) since there are no real disk paths.
    func currentLOCCommitted(repo: RepoInfo, projectPath: String, excludedFolders: Set<String>,
                             branch: String, now: Date, cache: RepoFileCache)
        async -> (CodeStats, RepoFileCache, [StatFileEntry]) {
        // Resolve the committed tree SHA for this branch (used as the cache key).
        let treeSHA: String
        if let r = try? await runner.runOK(
            "git", ["-C", repo.path, "rev-parse", "\(branch)^{tree}"], timeout: 10
        ) {
            treeSHA = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            treeSHA = ""
        }
        let newScanKey = "committed:\(branch):\(treeSHA)"

        // HEAD for the committed branch (different from repo.path's HEAD when the branch
        // isn't checked out there). Use it so history() stays independent of LOC.
        let branchHead: String
        if let r = try? await runner.runOK(
            "git", ["-C", repo.path, "rev-parse", branch], timeout: 10
        ) {
            branchHead = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            branchHead = ""
        }

        // Bust the per-file cache when the scan anchor OR the committed tree changes.
        var reuse = cache.files
        if cache.scanKey != newScanKey { reuse = [:] }

        // List files in the committed tree: `git ls-tree -r --name-only <branch>`
        guard let listResult = try? await runner.runOK(
            "git", ["-C", repo.path, "ls-tree", "-r", "--name-only", branch], timeout: 60
        ) else {
            return (Self.emptyStats(now: now), RepoFileCache(head: branchHead, files: [:], scanKey: newScanKey), [])
        }
        let relPaths = listResult.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        // Build a synthetic `.ignorestats` scope. We need the content of any
        // `.ignorestats` files that exist in the committed tree — read them via cat-file.
        // There are typically very few (0–2) of these, so one process per file is fine.
        var ignoreFrames: [GitignoreScope.Frame] = []
        for rel in relPaths where (rel as NSString).lastPathComponent == ".ignorestats" {
            if let r = try? await runner.runOK(
                "git", ["-C", repo.path, "cat-file", "blob", "\(branch):\(rel)"], timeout: 10
            ) {
                let dir = (rel as NSString).deletingLastPathComponent
                ignoreFrames.append(GitignoreScope.Frame(directory: dir,
                                                         rules: GitignoreRules(contents: r.stdout)))
            }
        }
        ignoreFrames.sort { $0.directory.count < $1.directory.count }
        let ignoreScope = GitignoreScope(frames: ignoreFrames)

        let prefix = Self.projectRelativePrefix(repoPath: repo.path, projectPath: projectPath)

        struct Acc { var files = 0; var code = 0; var comment = 0; var blank = 0 }
        var byLang: [String: Acc] = [:]
        var skippedBinary = 0
        var nextFiles: [String: CachedClassified] = [:]
        var filesForResult: [StatFileEntry] = []

        // Pass 1: collect every file that passes the pre-filters (skipped dirs, language,
        // ignorestats) into a struct so we can batch-fetch all cache-miss blobs in one
        // `git cat-file --batch` process instead of spawning one child per file.
        struct PendingFile {
            let rel: String
            let lang: LanguageDefinition
            let projectRel: String
            let isExcluded: Bool
            let cacheKey: String
            let cachedClassification: FileClassification?  // non-nil → cache hit
        }
        var pending: [PendingFile] = []
        // Object specs for cache-miss files (written to cat-file --batch stdin).
        var missSpecs: [String] = []

        for rel in relPaths {
            if rel.split(separator: "/").contains(where: { GitService.alwaysSkippedDirNames.contains(String($0)) }) {
                continue
            }
            guard let lang = CodeStatsEngine.language(forPath: rel) else { continue }
            let projectRel = prefix.isEmpty ? rel : prefix + "/" + rel
            if ignoreScope.isIgnored(path: rel, isDirectory: false) { continue }
            let isExcluded = excludedFolders.contains {
                projectRel == $0 || projectRel.hasPrefix($0 + "/")
            }
            let cacheKey = "\(branch)/\(rel)"
            let cached: FileClassification?
            if let hit = reuse[cacheKey], !treeSHA.isEmpty {
                cached = hit.classification
            } else {
                cached = nil
                missSpecs.append("\(branch):\(rel)")
            }
            pending.append(PendingFile(rel: rel, lang: lang, projectRel: projectRel,
                                       isExcluded: isExcluded, cacheKey: cacheKey,
                                       cachedClassification: cached))
        }

        // Pass 2: fetch all cache-miss blobs via ONE `git cat-file --batch` process.
        //
        // Pipe-deadlock safety: `git cat-file --batch` writes one blob response per
        // spec it reads, so stdout can fill up before all specs are written. We run
        // three concurrent detached tasks to avoid all forms of blocking:
        //   • stdinTask  – writes all specs then closes stdin (signals EOF to git)
        //   • stdoutTask – drains stdout continuously (binary-safe readDataToEndOfFile)
        //   • stderrTask – drains stderr (prevents git from blocking on a full stderr pipe)
        // We then await process exit via terminationHandler + AsyncStream (never blocks a
        // cooperative thread), await all three drain tasks, and parse the collected output.
        var blobBySpec: [String: Data] = [:]  // spec → raw blob bytes
        if !missSpecs.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            environment["GIT_TERMINAL_PROMPT"] = "0"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", repo.path, "cat-file", "--batch"]
            process.environment = environment
            process.currentDirectoryURL = URL(fileURLWithPath: repo.path, isDirectory: true)

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Install terminationHandler BEFORE run() so we cannot miss an early exit.
            let exitStream = AsyncStream<Void> { continuation in
                process.terminationHandler = { _ in
                    continuation.yield(())
                    continuation.finish()
                }
            }

            var launched = false
            do { try process.run(); launched = true } catch { /* blobBySpec stays empty */ }

            if launched {
                let input = (missSpecs.joined(separator: "\n") + "\n")
                    .data(using: .utf8) ?? Data()

                // All three pipe directions run concurrently on background threads so no
                // cooperative Swift concurrency thread is blocked by pipe I/O.
                let stdinTask = Task.detached {
                    stdinPipe.fileHandleForWriting.write(input)
                    stdinPipe.fileHandleForWriting.closeFile()
                }
                let stdoutTask = Task.detached {
                    stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                }
                let stderrTask = Task.detached {
                    stderrPipe.fileHandleForReading.readDataToEndOfFile()
                }

                // Wait for process termination (non-blocking: uses terminationHandler).
                for await _ in exitStream {}

                // Await all pipe drains after exit (they will complete quickly once the
                // process has exited and the pipes hit EOF).
                await stdinTask.value
                let stdoutData = await stdoutTask.value
                _ = await stderrTask.value

                // Parse the framed `git cat-file --batch` output. Each object is:
                //   <object-name> SP <type> SP <size> LF
                //   <size bytes of content>
                //   LF
                // On a missing object: <object-name> SP "missing" LF  (no payload).
                blobBySpec = Self.parseCatFileBatch(stdoutData, specs: missSpecs)
            }
        }

        // Pass 3: classify each file using the batch-fetched blobs or cached results.
        var missSpecIndex = 0
        for pf in pending {
            let classification: FileClassification
            if let cached = pf.cachedClassification {
                classification = cached
            } else {
                // Pop the next miss spec (order preserved from Pass 1).
                let spec = missSpecIndex < missSpecs.count ? missSpecs[missSpecIndex] : ""
                missSpecIndex += 1
                guard let blobData = blobBySpec[spec] else { continue }
                if CodeStatsEngine.isLikelyBinary(blobData) {
                    skippedBinary += 1
                    continue
                }
                classification = CodeStatsEngine.classify(
                    contents: String(decoding: blobData, as: UTF8.self), language: pf.lang)
                // (Note: cache miss entries are stored below, outside this branch.)
            }

            filesForResult.append(StatFileEntry(
                path: pf.projectRel,
                lines: classification.code + classification.comment + classification.blank,
                language: pf.lang.name,
                isDataProse: CodeStatsEngine.isDataProse(pf.lang.name),
                isExcluded: pf.isExcluded))
            if pf.isExcluded { continue }

            nextFiles[pf.cacheKey] = CachedClassified(
                mtime: .distantPast, size: 0, language: pf.lang.name, classification: classification)
            var acc = byLang[pf.lang.name] ?? Acc()
            acc.files += 1
            acc.code += classification.code
            acc.comment += classification.comment
            acc.blank += classification.blank
            byLang[pf.lang.name] = acc
        }

        let byLanguage = byLang.map { name, acc in
            LanguageStats(language: name, files: acc.files, code: acc.code,
                          comment: acc.comment, blank: acc.blank,
                          total: acc.code + acc.comment + acc.blank)
        }.sorted { $0.code > $1.code }
        let totalFiles = byLanguage.reduce(0) { $0 + $1.files }
        let code = byLanguage.reduce(0) { $0 + $1.code }
        let comment = byLanguage.reduce(0) { $0 + $1.comment }
        let blank = byLanguage.reduce(0) { $0 + $1.blank }
        let stats = CodeStats(totalFiles: totalFiles, totalLines: code + comment + blank,
                              code: code, comment: comment, blank: blank,
                              byLanguage: byLanguage, scannedAt: now, skippedBinary: skippedBinary)
        return (stats, RepoFileCache(head: branchHead, files: nextFiles, scanKey: newScanKey), filesForResult)
    }

    /// The PROJECT-root-relative directory prefix for a repo: `repoPath` made relative
    /// to `projectPath` (both symlink-resolved so git's `/private/var/…` paths compare
    /// cleanly). Returns "" when the repo IS the project root, or when `repoPath` is not
    /// under `projectPath` (a defensive fallback — the discovery walk only yields repos
    /// inside the project). Pure string math on standardized components, mirroring the
    /// `standardize` convention used elsewhere in this service.
    static func projectRelativePrefix(repoPath: String, projectPath: String) -> String {
        let repoComps = URL(fileURLWithPath: standardize(repoPath)).pathComponents
        let projComps = URL(fileURLWithPath: standardize(projectPath)).pathComponents
        guard repoComps.count >= projComps.count else { return "" }
        for i in 0..<projComps.count where repoComps[i] != projComps[i] { return "" }
        return repoComps[projComps.count...].joined(separator: "/")
    }

    /// Build a `GitignoreScope` from every `.ignorestats` file in `relPaths` (repo-
    /// relative). Each `.ignorestats` is read from disk and parsed by the shared
    /// `GitignoreRules`; its frame's `directory` is the file's parent dir (repo-relative,
    /// "" at the repo root), so matching a repo-relative candidate path honors the
    /// nearest enclosing list deepest-first — exactly git's `.gitignore` precedence.
    static func buildIgnoreStatsScope(relPaths: [String], base: URL) -> GitignoreScope {
        var frames: [GitignoreScope.Frame] = []
        for rel in relPaths where (rel as NSString).lastPathComponent == ".ignorestats" {
            guard let contents = try? String(contentsOf: base.appendingPathComponent(rel), encoding: .utf8)
            else { continue }
            let dir = (rel as NSString).deletingLastPathComponent  // "" at repo root
            frames.append(GitignoreScope.Frame(directory: dir, rules: GitignoreRules(contents: contents)))
        }
        // Shallower frames first so the scope's deepest-first traversal (it reverses the
        // array) gives the deepest `.ignorestats` precedence.
        frames.sort { $0.directory.count < $1.directory.count }
        return GitignoreScope(frames: frames)
    }

    // MARK: History + delta

    /// Resolves the repo's EFFECTIVE default branch. The history/delta must describe the
    /// branch the user is actually working on, so the checked-out branch (HEAD's symbolic
    /// ref) is preferred over the origin/HEAD "master" guess: a repo on a feature branch
    /// (e.g. `refactor/bloc-to-vm-migration`) was previously summarized against master,
    /// describing a tree the working copy no longer matched. Order:
    ///   1. the current checked-out branch (`git symbolic-ref --short HEAD`), if it's a real ref;
    ///   2. the origin/HEAD-detected base branch (main/master/dev fallback inside);
    ///   3. `HEAD` as the last resort (detached HEAD, etc).
    /// The per-repo branch override (in `scan`) still wins over this.
    func resolveBranch(repo: RepoInfo) async -> String {
        let current = await git.currentBranch(repoPath: repo.path)
        if !current.isEmpty, await git.branchExists(repoPath: repo.path, current) {
            return current
        }
        let base = await git.baseBranch(repo: repo, override: nil)
        // `base` may now be a remote-tracking ref (origin/<name>), which
        // `branchExists` (refs/heads-scoped) would reject — use `refExists`.
        if await git.refExists(repoPath: repo.path, base) { return base }
        return "HEAD"
    }

    /// Per-day cumulative history and the period delta on `branch`, parsed from
    /// `git log --numstat`. Degrades to ([], .zero) for an empty repo or git failure.
    func history(repo: RepoInfo, branch: String, period: TimeInterval, now: Date)
        async -> ([RepoHistoryPoint], RepoDelta) {
        guard let result = try? await runner.runOK(
            "git", ["-C", repo.path, "log", "--numstat", "--no-renames",
                    "--format=%x01%H%x02%ct", branch],
            timeout: 120
        ) else {
            return ([], .zero)
        }
        let commits = Self.parseLog(result.stdout)
        let history = Self.bucketHistory(commits: commits)
        let delta = Self.delta(commits: commits, period: period, now: now)
        return (history, delta)
    }

    /// HEAD sha (the cache invalidation key). Empty repos / failures → "".
    func head(repo: RepoInfo) async -> String {
        await headAt(path: repo.path)
    }

    /// HEAD sha at an arbitrary git working tree path. Empty repos / failures → "".
    func headAt(path: String) async -> String {
        guard let result = try? await runner.run(
            "git", ["-C", path, "rev-parse", "HEAD"], cwd: nil, env: nil, timeout: 10
        ), result.exitCode == 0 else { return "" }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Pure parsing/aggregation helpers (unit-tested directly)

    /// Splits NUL-separated `git ls-files -z` output into repo-relative paths,
    /// dropping the trailing empty element.
    static func parseLsFilesZ(_ output: String) -> [String] {
        output.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
    }

    /// One parsed commit: its committer timestamp plus the additions/deletions and
    /// the set of non-binary paths it touched. `added`/`removed` are the all-language
    /// totals (kept whole for the churn bars); `code*`/`data*` partition the same
    /// totals by language group (`codeAdded + dataAdded == added`, likewise removed).
    struct ParsedCommit {
        let date: Date
        var added: Int
        var removed: Int
        var codeAdded: Int = 0
        var codeRemoved: Int = 0
        var dataAdded: Int = 0
        var dataRemoved: Int = 0
        var paths: Set<String>
    }

    /// Parses `git log --numstat --format=%x01%H%x02%ct`. Each commit record starts
    /// with a line beginning `\u{01}` (`%H` then `\u{02}` then the UNIX `%ct`).
    /// Subsequent `<add>\t<del>\t<path>` numstat lines accumulate into the current
    /// commit; binary files ("-"/"-") are skipped. Output is newest-first.
    ///
    /// Each numstat path is classified by `CodeStatsEngine.language(forPath:)`. A path with
    /// NO known language (`.txt`, lock files, `.pbxproj`, build artifacts, extensionless
    /// files) is SKIPPED — matching the working-tree scan (`currentLOC`), which also drops
    /// unrecognized files, so the "Lines over time" history measures the same recognized
    /// source the Totals card does. Of the recognized files, a Data/Prose language
    /// (Markdown/JSON/YAML/TOML) accumulates into `data*` and every other recognized language
    /// into `code*`, preserving the `code + data == total` invariant (both recognized-only).
    static func parseLog(_ output: String) -> [ParsedCommit] {
        var commits: [ParsedCommit] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("\u{01}") {
                // Header: \u{01}<sha>\u{02}<ct>
                let body = line.dropFirst()
                let parts = body.split(separator: "\u{02}", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let ct = TimeInterval(parts[1].trimmingCharacters(in: .whitespaces)) else {
                    continue
                }
                commits.append(ParsedCommit(date: Date(timeIntervalSince1970: ct),
                                            added: 0, removed: 0, paths: []))
            } else {
                // Numstat line: <add>\t<del>\t<path>
                guard !commits.isEmpty else { continue }
                let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count >= 3, !fields[2].isEmpty else { continue }
                guard let add = Int(fields[0]), let del = Int(fields[1]) else { continue }  // "-" → binary, skip
                let path = String(fields[2])
                // Match the working-tree scan exactly so "Lines over time" measures the SAME
                // source the Totals card does. (1) Drop generated/vendored infrastructure dirs
                // (node_modules, build, dist, .next, target, .worktrees…) — the scan skips
                // these (`alwaysSkippedDirNames`), so a committed build tree can't inflate the
                // history above the Totals. (2) Count ONLY recognized-language files; a path
                // with no known language (lock files, .pbxproj, CMake/Ninja output, logs,
                // .txt, unknown extensions) is dropped — `currentLOC`'s `language(forPath:)`
                // guard drops it from the Totals too. Of the recognized files, Data/Prose →
                // data bucket, every other → code; `code + data == total` still holds.
                if path.split(separator: "/")
                    .contains(where: { GitService.alwaysSkippedDirNames.contains(String($0)) }) {
                    continue
                }
                guard let lang = CodeStatsEngine.language(forPath: path) else { continue }
                let isData = CodeStatsEngine.isDataProse(lang.name)
                let i = commits.count - 1
                commits[i].added += add
                commits[i].removed += del
                if isData {
                    commits[i].dataAdded += add
                    commits[i].dataRemoved += del
                } else {
                    commits[i].codeAdded += add
                    commits[i].codeRemoved += del
                }
                commits[i].paths.insert(path)
            }
        }
        return commits
    }

    /// GMT calendar so day bucketing is deterministic regardless of the host tz.
    /// Public so the GroveAppKit presentation layer (`stackedRepoSeries`) can fill calendar
    /// days against the SAME tz the history was bucketed in.
    public static let gmtCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "GMT")!
        return cal
    }()

    /// Collapses commits into one cumulative point per calendar day. Walks
    /// chronologically maintaining a running net total; multiple commits on the same day
    /// collapse to a single point carrying the END-OF-DAY cumulative.
    ///
    /// Sorts by commit DATE rather than trusting `git log`'s default order: `git log`
    /// emits reverse-GRAPH (topology) order, where a child can carry an EARLIER timestamp
    /// than its parent (routine after rebase/cherry-pick/amend/squash, or clock skew). A
    /// plain `.reversed()` would then accumulate `running` out of time order, attribute
    /// the wrong cumulative to each day, AND return points that aren't date-sorted —
    /// breaking both the per-repo chart and `aggregateHistory`'s on-or-before lookup
    /// (which relies on oldest-first ordering).
    static func bucketHistory(commits: [ParsedCommit]) -> [RepoHistoryPoint] {
        guard !commits.isEmpty else { return [] }
        let cal = gmtCalendar
        let chronological = commits.sorted { $0.date < $1.date }
        var running = 0
        // Ordered list of days; last-write-wins on the cumulative per day. The per-day
        // added/removed ACCUMULATE across same-day commits (sum, not last-write-wins),
        // while `netLines` carries the END-OF-DAY cumulative.
        var order: [Date] = []
        var byDay: [Date: Int] = [:]
        var addedByDay: [Date: Int] = [:]
        var removedByDay: [Date: Int] = [:]
        var codeAddedByDay: [Date: Int] = [:]
        var codeRemovedByDay: [Date: Int] = [:]
        var dataAddedByDay: [Date: Int] = [:]
        var dataRemovedByDay: [Date: Int] = [:]
        for commit in chronological {
            running += commit.added - commit.removed
            let day = cal.startOfDay(for: commit.date)
            if byDay[day] == nil { order.append(day) }
            byDay[day] = running
            addedByDay[day, default: 0] += commit.added
            removedByDay[day, default: 0] += commit.removed
            codeAddedByDay[day, default: 0] += commit.codeAdded
            codeRemovedByDay[day, default: 0] += commit.codeRemoved
            dataAddedByDay[day, default: 0] += commit.dataAdded
            dataRemovedByDay[day, default: 0] += commit.dataRemoved
        }
        return order.map {
            RepoHistoryPoint(date: $0, netLines: byDay[$0]!,
                             dayAdded: addedByDay[$0] ?? 0, dayRemoved: removedByDay[$0] ?? 0,
                             codeAdded: codeAddedByDay[$0] ?? 0, codeRemoved: codeRemovedByDay[$0] ?? 0,
                             dataAdded: dataAddedByDay[$0] ?? 0, dataRemoved: dataRemovedByDay[$0] ?? 0)
        }
    }

    /// Sums additions/deletions over commits within `[now - period, now]`, plus the
    /// count of distinct paths touched in that window.
    static func delta(commits: [ParsedCommit], period: TimeInterval, now: Date) -> RepoDelta {
        let cutoff = now.addingTimeInterval(-period)
        var added = 0, removed = 0
        var paths: Set<String> = []
        for commit in commits where commit.date >= cutoff && commit.date <= now {
            added += commit.added
            removed += commit.removed
            paths.formUnion(commit.paths)
        }
        return RepoDelta(added: added, removed: removed, filesChanged: paths.count)
    }

    /// Sums the classified code/data additions/deletions over commits within
    /// `[now - period, now]`. The same window as `delta`, partitioned by language group,
    /// so `code* + data*` equals `delta`'s `added`/`removed`. Tested directly.
    static func languageSplitDelta(commits: [ParsedCommit], period: TimeInterval, now: Date) -> LanguageSplitDelta {
        let cutoff = now.addingTimeInterval(-period)
        var codeAdded = 0, codeRemoved = 0, dataAdded = 0, dataRemoved = 0
        for commit in commits where commit.date >= cutoff && commit.date <= now {
            codeAdded += commit.codeAdded
            codeRemoved += commit.codeRemoved
            dataAdded += commit.dataAdded
            dataRemoved += commit.dataRemoved
        }
        return LanguageSplitDelta(codeAdded: codeAdded, codeRemoved: codeRemoved,
                                  dataAdded: dataAdded, dataRemoved: dataRemoved)
    }

    /// Aggregates per-repo results into a `ProjectGitStats`: element-wise sum of the
    /// current-LOC `CodeStats`, a carry-forward-summed per-day history, and a summed
    /// delta.
    public static func aggregate(_ repos: [RepoStats], now: Date) -> ProjectGitStats {
        // Current LOC sum: merge byLanguage by name, sum scalar totals.
        var byLangCode: [String: Int] = [:]
        var byLangComment: [String: Int] = [:]
        var byLangBlank: [String: Int] = [:]
        var byLangFiles: [String: Int] = [:]
        var totalFiles = 0, code = 0, comment = 0, blank = 0, skippedBinary = 0
        for repo in repos {
            let s = repo.stats
            totalFiles += s.totalFiles
            code += s.code
            comment += s.comment
            blank += s.blank
            skippedBinary += s.skippedBinary
            for lang in s.byLanguage {
                byLangCode[lang.language, default: 0] += lang.code
                byLangComment[lang.language, default: 0] += lang.comment
                byLangBlank[lang.language, default: 0] += lang.blank
                byLangFiles[lang.language, default: 0] += lang.files
            }
        }
        let byLanguage = byLangCode.keys.map { name in
            LanguageStats(language: name, files: byLangFiles[name] ?? 0,
                          code: byLangCode[name] ?? 0, comment: byLangComment[name] ?? 0,
                          blank: byLangBlank[name] ?? 0,
                          total: (byLangCode[name] ?? 0) + (byLangComment[name] ?? 0) + (byLangBlank[name] ?? 0))
        }.sorted { $0.code > $1.code }
        let aggregate = CodeStats(totalFiles: totalFiles, totalLines: code + comment + blank,
                                  code: code, comment: comment, blank: blank,
                                  byLanguage: byLanguage, scannedAt: now, skippedBinary: skippedBinary)

        // History sum: union all repo days; on each day, sum each repo's cumulative
        // net AS OF that day (carry forward each repo's last-known cumulative across
        // days where it had no commit).
        let aggregateHistory = Self.aggregateHistory(repos: repos)

        // Delta sum.
        let added = repos.reduce(0) { $0 + $1.delta.added }
        let removed = repos.reduce(0) { $0 + $1.delta.removed }
        let filesChanged = repos.reduce(0) { $0 + $1.delta.filesChanged }
        let aggregateDelta = RepoDelta(added: added, removed: removed, filesChanged: filesChanged)

        // Flatten every repo's per-file list (already project-relative, globally unique
        // by path) into one project-wide list, sorted by path for stable display/tests.
        let files = repos.flatMap(\.files).sorted { $0.path < $1.path }

        return ProjectGitStats(repos: repos, aggregate: aggregate,
                               aggregateHistory: aggregateHistory, aggregateDelta: aggregateDelta,
                               scannedAt: now, files: files)
    }

    /// Carry-forward-summed per-day history across repos. For each distinct day in the
    /// union of all repos' histories, the project total is the sum over repos of that
    /// repo's most recent cumulative net AT OR BEFORE that day (0 before its first
    /// commit). Maps to `CodeStatsPoint` with `totalLines == code == summedNet` so the
    /// existing growth chart (which plots `totalLines`) reads correctly; comment/blank/
    /// files are not derivable from numstat and are 0.
    static func aggregateHistory(repos: [RepoStats]) -> [CodeStatsPoint] {
        let allDays = Set(repos.flatMap { $0.history.map(\.date) }).sorted()
        guard !allDays.isEmpty else { return [] }
        return allDays.map { day in
            var total = 0
            var dayAdded = 0, dayRemoved = 0
            var codeAdded = 0, codeRemoved = 0, dataAdded = 0, dataRemoved = 0
            for repo in repos {
                // Cumulative net: last point on or before `day` (history is oldest-first).
                var value = 0
                for point in repo.history {
                    if point.date <= day { value = point.netLines } else { break }
                }
                total += value
                // Per-day added/removed are POINT-IN-DAY (not carry-forward): only the
                // repo's exact `day` point contributes; a repo with no commit that day
                // adds 0. This is what lets the UI re-sum any window without a re-scan.
                if let p = repo.history.first(where: { $0.date == day }) {
                    dayAdded += p.dayAdded
                    dayRemoved += p.dayRemoved
                    codeAdded += p.codeAdded
                    codeRemoved += p.codeRemoved
                    dataAdded += p.dataAdded
                    dataRemoved += p.dataRemoved
                }
            }
            return CodeStatsPoint(date: day, totalLines: total, code: total,
                                  comment: 0, blank: 0, totalFiles: 0,
                                  dayAdded: dayAdded, dayRemoved: dayRemoved,
                                  codeAdded: codeAdded, codeRemoved: codeRemoved,
                                  dataAdded: dataAdded, dataRemoved: dataRemoved)
        }
    }

    /// An all-zero `CodeStats` for a failed/empty repo.
    static func emptyStats(now: Date) -> CodeStats {
        CodeStats(totalFiles: 0, totalLines: 0, code: 0, comment: 0, blank: 0,
                  byLanguage: [], scannedAt: now, skippedBinary: 0)
    }

    // MARK: cat-file --batch frame parser

    /// Parses the framed stdout of `git cat-file --batch` and returns a map from
    /// object-spec to raw blob bytes. Each blob response has the format:
    ///
    ///   <object-name> SP "blob" SP <size> LF   ← header line
    ///   <size bytes of raw content>             ← payload (binary-safe)
    ///   LF                                      ← trailing newline after payload
    ///
    /// Missing objects produce:  <object-name> SP "missing" LF  (no payload).
    ///
    /// `specs` is the ordered list of object specs that were fed to stdin; it is used
    /// to match responses back when the object-name in the header differs from the
    /// spec we wrote (e.g. git may normalise the name). Pairing is positional — the
    /// N-th non-missing response corresponds to the N-th spec in the ordered list.
    /// (In practice `git cat-file --batch` echoes our spec verbatim, so the name in
    /// the header equals what we wrote; the positional fallback is belt-and-suspenders.)
    static func parseCatFileBatch(_ data: Data, specs: [String]) -> [String: Data] {
        var result: [String: Data] = [:]
        var pos = data.startIndex
        var specIndex = 0

        // Scan byte-by-byte for the LF that terminates the header line.
        func nextLine() -> Data? {
            guard pos < data.endIndex else { return nil }
            var end = pos
            while end < data.endIndex && data[end] != UInt8(ascii: "\n") {
                end = data.index(after: end)
            }
            if end >= data.endIndex { return nil }
            let line = data[pos..<end]
            pos = data.index(after: end)  // skip the LF itself
            return Data(line)
        }

        while pos < data.endIndex, specIndex < specs.count {
            guard let headerData = nextLine(),
                  let header = String(data: headerData, encoding: .utf8) else { break }

            let parts = header.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { specIndex += 1; continue }

            let objectName = String(parts[0])
            let typeOrMissing = String(parts[1])

            if typeOrMissing == "missing" {
                // No payload; advance spec index so we stay in sync.
                specIndex += 1
                continue
            }

            // Expect: <name> blob <size>
            guard parts.count == 3, typeOrMissing == "blob",
                  let size = Int(parts[2].trimmingCharacters(in: .whitespaces)) else {
                // Non-blob or malformed header; skip to next record.
                specIndex += 1
                continue
            }

            // Read exactly `size` bytes of payload.
            guard pos <= data.endIndex else { break }
            let payloadEnd = data.index(pos, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            let payload = Data(data[pos..<payloadEnd])
            pos = payloadEnd

            // Skip the mandatory trailing LF after the payload (if still in bounds).
            if pos < data.endIndex && data[pos] == UInt8(ascii: "\n") {
                pos = data.index(after: pos)
            }

            // Map by the echo'd object name, AND by the original spec (belt-and-suspenders).
            let spec = specs[specIndex]
            result[spec] = payload
            if objectName != spec {
                result[objectName] = payload
            }
            specIndex += 1
        }

        return result
    }
}
