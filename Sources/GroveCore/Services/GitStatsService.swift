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
    /// `dayAdded`/`dayRemoved` default to 0 so existing call sites and Codable decodes
    /// of pre-existing JSON (which lack these keys) keep working.
    public init(date: Date, netLines: Int, dayAdded: Int = 0, dayRemoved: Int = 0) {
        self.date = date
        self.netLines = netLines
        self.dayAdded = dayAdded
        self.dayRemoved = dayRemoved
    }

    // Custom decode so older persisted JSON (no dayAdded/dayRemoved keys) still loads,
    // defaulting the missing per-day fields to 0.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.date = try c.decode(Date.self, forKey: .date)
        self.netLines = try c.decode(Int.self, forKey: .netLines)
        self.dayAdded = try c.decodeIfPresent(Int.self, forKey: .dayAdded) ?? 0
        self.dayRemoved = try c.decodeIfPresent(Int.self, forKey: .dayRemoved) ?? 0
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

/// Full per-repo result: current LOC (reuses the existing `CodeStats` shape),
/// per-day cumulative history, and a period delta.
public struct RepoStats: Sendable, Equatable {
    public let repoPath: String        // absolute, standardized
    public let repoName: String        // leaf directory name
    public let defaultBranch: String
    public let stats: CodeStats        // REUSED: current LOC, byLanguage, totals
    public let history: [RepoHistoryPoint]   // per-day cumulative net lines, oldest first
    public let delta: RepoDelta              // over the requested period
    public init(repoPath: String, repoName: String, defaultBranch: String,
                stats: CodeStats, history: [RepoHistoryPoint], delta: RepoDelta) {
        self.repoPath = repoPath
        self.repoName = repoName
        self.defaultBranch = defaultBranch
        self.stats = stats
        self.history = history
        self.delta = delta
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
    public init(repos: [RepoStats], aggregate: CodeStats,
                aggregateHistory: [CodeStatsPoint], aggregateDelta: RepoDelta, scannedAt: Date) {
        self.repos = repos
        self.aggregate = aggregate
        self.aggregateHistory = aggregateHistory
        self.aggregateDelta = aggregateDelta
        self.scannedAt = scannedAt
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
public struct RepoFileCache: Sendable, Equatable {
    public var head: String                       // HEAD sha at last scan ("" for empty repo)
    public var files: [String: CachedClassified]  // keyed by ABSOLUTE path
    public init(head: String = "", files: [String: CachedClassified] = [:]) {
        self.head = head
        self.files = files
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
        period: TimeInterval = GitStatsService.defaultPeriod,
        now: Date = Date(),
        cache: inout [String: RepoFileCache]
    ) async -> ProjectGitStats {
        let repos = await reposToScan(projectPath: projectPath, scanDepth: scanDepth,
                                      excluded: excludedRepos)
        var repoStats: [RepoStats] = []
        for repo in repos {
            var repoCache = cache[repo.path] ?? RepoFileCache()
            let (stats, updated) = await currentLOC(repo: repo, now: now, cache: repoCache)
            repoCache = updated
            cache[repo.path] = repoCache

            let branch = await resolveBranch(repo: repo)
            let (history, delta) = await history(repo: repo, branch: branch,
                                                 period: period, now: now)
            repoStats.append(RepoStats(
                repoPath: repo.path, repoName: repo.dirName, defaultBranch: branch,
                stats: stats, history: history, delta: delta))
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
        guard !worktreePaths.isEmpty else { return repos }
        return repos.filter { !worktreePaths.contains(Self.standardize($0.path)) }
    }

    /// git emits symlink-resolved paths (/private/var/… on macOS); standardize both
    /// sides so the worktree filter compares apples to apples.
    static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: Current LOC

    /// Classifies the repo's current file set (tracked + untracked-not-ignored).
    /// Returns the `CodeStats` and the UPDATED per-repo cache. Degrades to empty
    /// stats (but a populated/cleared cache) on any git failure.
    func currentLOC(repo: RepoInfo, now: Date, cache: RepoFileCache) async -> (CodeStats, RepoFileCache) {
        let head = await self.head(repo: repo)
        // A changed HEAD invalidates the whole cache (a checkout/branch switch
        // remaps path→content, so per-file mtime reuse can't be trusted across it).
        var reuse = cache.files
        if cache.head != head { reuse = [:] }

        guard let result = try? await runner.runOK(
            "git", ["-C", repo.path, "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            timeout: 60
        ) else {
            return (Self.emptyStats(now: now), RepoFileCache(head: head, files: [:]))
        }

        let relPaths = Self.parseLsFilesZ(result.stdout)
        let fm = FileManager.default
        let base = URL(fileURLWithPath: repo.path, isDirectory: true)

        // Accumulators keyed by language name.
        struct Acc { var files = 0; var code = 0; var comment = 0; var blank = 0 }
        var byLang: [String: Acc] = [:]
        var skippedBinary = 0
        var nextFiles: [String: CachedClassified] = [:]

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
        return (stats, RepoFileCache(head: head, files: nextFiles))
    }

    // MARK: History + delta

    /// Resolves the repo's default branch, falling back to HEAD when the detected
    /// branch isn't a real ref (e.g. a repo whose only branch isn't main/master/dev).
    func resolveBranch(repo: RepoInfo) async -> String {
        let branch = await git.baseBranch(repo: repo, override: nil)
        if await git.branchExists(repoPath: repo.path, branch) { return branch }
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
        guard let result = try? await runner.run(
            "git", ["-C", repo.path, "rev-parse", "HEAD"], cwd: nil, env: nil, timeout: 10
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
    /// the set of non-binary paths it touched.
    struct ParsedCommit {
        let date: Date
        var added: Int
        var removed: Int
        var paths: Set<String>
    }

    /// Parses `git log --numstat --format=%x01%H%x02%ct`. Each commit record starts
    /// with a line beginning `\u{01}` (`%H` then `\u{02}` then the UNIX `%ct`).
    /// Subsequent `<add>\t<del>\t<path>` numstat lines accumulate into the current
    /// commit; binary files ("-"/"-") are skipped. Output is newest-first.
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
                commits[commits.count - 1].added += add
                commits[commits.count - 1].removed += del
                commits[commits.count - 1].paths.insert(String(fields[2]))
            }
        }
        return commits
    }

    /// GMT calendar so day bucketing is deterministic regardless of the host tz.
    static let gmtCalendar: Calendar = {
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
        for commit in chronological {
            running += commit.added - commit.removed
            let day = cal.startOfDay(for: commit.date)
            if byDay[day] == nil { order.append(day) }
            byDay[day] = running
            addedByDay[day, default: 0] += commit.added
            removedByDay[day, default: 0] += commit.removed
        }
        return order.map {
            RepoHistoryPoint(date: $0, netLines: byDay[$0]!,
                             dayAdded: addedByDay[$0] ?? 0, dayRemoved: removedByDay[$0] ?? 0)
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

    /// Aggregates per-repo results into a `ProjectGitStats`: element-wise sum of the
    /// current-LOC `CodeStats`, a carry-forward-summed per-day history, and a summed
    /// delta.
    static func aggregate(_ repos: [RepoStats], now: Date) -> ProjectGitStats {
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

        return ProjectGitStats(repos: repos, aggregate: aggregate,
                               aggregateHistory: aggregateHistory, aggregateDelta: aggregateDelta,
                               scannedAt: now)
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
                }
            }
            return CodeStatsPoint(date: day, totalLines: total, code: total,
                                  comment: 0, blank: 0, totalFiles: 0,
                                  dayAdded: dayAdded, dayRemoved: dayRemoved)
        }
    }

    /// An all-zero `CodeStats` for a failed/empty repo.
    static func emptyStats(now: Date) -> CodeStats {
        CodeStats(totalFiles: 0, totalLines: 0, code: 0, comment: 0, blank: 0,
                  byLanguage: [], scannedAt: now, skippedBinary: 0)
    }
}
