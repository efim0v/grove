import Foundation

public struct AccountIdentity: Sendable, Equatable {
    public let email: String?
    public let organization: String?
    public let tier: String?
    /// FIX I2: the CANONICAL tier namespace `RateLimitModel.tierWeights` keys on
    /// (e.g. `default_claude_max_20x`) — distinct from `tier`'s `userRateLimitTier`
    /// namespace (e.g. `max_20x`). The accounts card surfaces this one.
    public let organizationRateLimitTier: String?

    public init(email: String?, organization: String?, tier: String?,
                organizationRateLimitTier: String? = nil) {
        self.email = email
        self.organization = organization
        self.tier = tier
        self.organizationRateLimitTier = organizationRateLimitTier
    }
}

public struct ClaudeSession: Sendable, Equatable {
    public let id: String
    public let cwd: String
    public let title: String?
    public let lastActivity: Date
    public let accountName: String
    public let gitBranch: String?

    public init(id: String, cwd: String, title: String?, lastActivity: Date,
                accountName: String, gitBranch: String?) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.lastActivity = lastActivity
        self.accountName = accountName
        self.gitBranch = gitBranch
    }
}

public struct LiveProcess: Sendable, Equatable {
    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    public let status: String
    public let accountName: String
    /// Process start time parsed from the record's `startedAt` (ISO8601, both
    /// fractional variants — same parser as git commit dates). nil when the
    /// field is absent or unparseable. Drives the table's live-runtime column.
    public let startedAt: Date?

    public init(pid: Int32, sessionId: String, cwd: String, status: String,
                accountName: String, startedAt: Date? = nil) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.status = status
        self.accountName = accountName
        self.startedAt = startedAt
    }
}

public extension Array where Element == LiveProcess {
    /// The live process backing a session: matched by `sessionId` first, else by a
    /// FRESH (empty-id, cwd-carried) process sitting at the same working directory.
    ///
    /// Fresh sessions are launched as a bare `claude` (no `--resume`), so the process
    /// table can't attribute a session id to them — only their cwd. Matching by id
    /// alone would make every such running session read as "closed/resumable" and let
    /// a tap spawn a transcript-corrupting duplicate. The cwd is canonicalized so the
    /// macOS `/var` vs `/private/var` (and symlinked-worktree) spellings collapse to
    /// one form — a trailing-slash-only normalize misses that and silently drops the
    /// match. This is THE single id-or-cwd join every liveness surface must use so no
    /// tab disagrees (spec M2).
    func liveProcess(forSessionId id: String, cwd: String) -> LiveProcess? {
        if let byId = first(where: { $0.sessionId == id }) { return byId }
        let key = canonicalPath(cwd)
        return first { $0.sessionId.isEmpty && !$0.cwd.isEmpty && canonicalPath($0.cwd) == key }
    }
}

/// Reads Claude Code account identity, session transcripts and (Task 9) live processes
/// from a `CLAUDE_CONFIG_DIR`. A class (not a struct) so it can keep an mtime-keyed
/// parse cache: a jsonl file is re-parsed only when its modification date changes.
///
/// `@unchecked Sendable`: `sessionCache` is guarded by `cacheLock` and `processValidator`
/// is set once at construction, so one instance can be kept on AppState (so the parse
/// cache survives across scans — item 2 perf) and used from the background scan.
public final class ClaudeService: @unchecked Sendable {
    private struct ParsedSession {
        let id: String
        let cwd: String
        let title: String?
        let gitBranch: String?
    }

    private let cacheLock = NSLock()
    private var sessionCache: [String: (mtime: Date, parsed: ParsedSession?)] = [:]

    public init() {}

    // MARK: - cwd mangling

    /// Claude Code project-directory mangling: every Unicode scalar that is not
    /// ASCII [A-Za-z0-9] becomes "-". Example: "/a/b.c" -> "-a-b-c". Lossy.
    public static func mangle(_ absolutePath: String) -> String {
        String(absolutePath.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            let isAsciiAlnum = (v >= 0x30 && v <= 0x39)   // 0-9
                || (v >= 0x41 && v <= 0x5A)               // A-Z
                || (v >= 0x61 && v <= 0x7A)               // a-z
            return isAsciiAlnum ? Character(scalar) : "-"
        })
    }

    // MARK: - Account identity

    /// Default account (configDir == $HOME/.claude) keeps its identity in $HOME/.claude.json;
    /// custom accounts keep it in <configDir>/.claude.json. nil = not logged in / unreadable.
    /// Never reads tokens (those live in the Keychain — not our business).
    public func identity(account: AccountConfig) -> AccountIdentity? {
        let dir = expandTilde(account.configDir)
        let home = NSHomeDirectory()
        let jsonPath = (dir == home + "/.claude") ? home + "/.claude.json"
                                                  : dir + "/.claude.json"
        return Self.identity(claudeJSONPath: jsonPath)
    }

    /// Path-based variant so the `.claude.json` read can run OFF the main actor and be
    /// cached (the account-based version must not be called from a view body).
    public static func identity(claudeJSONPath: String) -> AccountIdentity? {
        guard
            let data = FileManager.default.contents(atPath: claudeJSONPath),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let oauth = object["oauthAccount"] as? [String: Any]
        else { return nil }
        return AccountIdentity(
            email: oauth["emailAddress"] as? String,
            organization: oauth["organizationName"] as? String,
            tier: oauth["userRateLimitTier"] as? String,
            organizationRateLimitTier: oauth["organizationRateLimitTier"] as? String
        )
    }

    /// The account's `organizationRateLimitTier` (e.g. "default_claude_max_20x")
    /// from `oauthAccount` in `<configDir>/.claude.json` (or `$HOME/.claude.json`
    /// for the default account). This is the canonical tier the rate-limit weight
    /// table (RateLimitModel.tierWeights) keys on — distinct from
    /// `userRateLimitTier` (identity().tier). nil = not logged in / field absent.
    public func organizationRateLimitTier(account: AccountConfig) -> String? {
        let dir = expandTilde(account.configDir)
        let home = NSHomeDirectory()
        let jsonPath = (dir == home + "/.claude") ? home + "/.claude.json"
                                                  : dir + "/.claude.json"
        return Self.organizationRateLimitTier(claudeJSONPath: jsonPath)
    }

    /// Path-based variant so the (synchronous) `.claude.json` read can run OFF the
    /// main actor — view bodies must never call the account-based version (it would
    /// read+parse the file on the main thread on every render). Resolve once in the
    /// off-main refresh and cache the result.
    public static func organizationRateLimitTier(claudeJSONPath: String) -> String? {
        guard
            let data = FileManager.default.contents(atPath: claudeJSONPath),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let oauth = object["oauthAccount"] as? [String: Any]
        else { return nil }
        return oauth["organizationRateLimitTier"] as? String
    }

    // MARK: - Sessions

    /// Sessions of `account` whose transcript belongs to `cwd`:
    /// `<configDir>/projects/<mangle(cwd)>/*.jsonl`, regular files only (subdirectories
    /// skipped), verified by the first record carrying a "cwd" key (mangling is lossy).
    /// Sorted newest first by file mtime.
    public func sessions(for cwd: String, account: AccountConfig) -> [ClaudeSession] {
        let fm = FileManager.default
        let dir = expandTilde(account.configDir) + "/projects/" + ClaudeService.mangle(cwd)
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var result: [ClaudeSession] = []
        for name in names where name.hasSuffix(".jsonl") {
            let path = dir + "/" + name
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            guard
                let attributes = try? fm.attributesOfItem(atPath: path),
                let mtime = attributes[.modificationDate] as? Date
            else { continue }
            guard let parsed = cachedParse(path: path, mtime: mtime),
                  parsed.cwd == cwd else { continue }
            result.append(ClaudeSession(
                id: parsed.id,
                cwd: parsed.cwd,
                title: parsed.title,
                lastActivity: mtime,
                accountName: account.name,
                gitBranch: parsed.gitBranch
            ))
        }
        return result.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Recent sessions whose real cwd is under any of `roots` (expanded absolute
    /// paths), across all `accounts`, newest first by file mtime, capped at
    /// `limit`. Deliberately CHEAP (item 2): it lists transcript files, prefilters
    /// directories by the mangled-root prefix, and parses only a bounded buffer of
    /// the newest candidates to confirm the real cwd + read the title — never the
    /// whole transcript corpus, and no git/cmux. Powers the Projects tab's
    /// per-project session previews without a full workspace scan.
    public func recentSessions(underRoots roots: [String], accounts: [AccountConfig],
                               limit: Int) -> [ClaudeSession] {
        guard limit > 0, !roots.isEmpty else { return [] }
        let fm = FileManager.default
        let canonRoots = roots.map { canonicalPath($0) }
        let mangledPrefixes = Set(roots.map { ClaudeService.mangle($0) }
            + canonRoots.map { ClaudeService.mangle($0) })

        struct Candidate { let path: String; let mtime: Date; let account: String }
        var candidates: [Candidate] = []
        for account in accounts {
            let projectsDir = expandTilde(account.configDir) + "/projects"
            guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { continue }
            for dir in dirs where mangledPrefixes.contains(where: { dir.hasPrefix($0) }) {
                let dirPath = projectsDir + "/" + dir
                guard let names = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
                for name in names where name.hasSuffix(".jsonl") {
                    let path = dirPath + "/" + name
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
                          let attrs = try? fm.attributesOfItem(atPath: path),
                          let mtime = attrs[.modificationDate] as? Date else { continue }
                    candidates.append(Candidate(path: path, mtime: mtime, account: account.name))
                }
            }
        }
        candidates.sort { $0.mtime > $1.mtime }

        var rows: [ClaudeSession] = []
        var seen = Set<String>()
        let budget = limit * 4 + 8   // bounded: only the newest candidates get parsed
        for cand in candidates.prefix(budget) {
            guard let parsed = cachedParse(path: cand.path, mtime: cand.mtime) else { continue }
            let canonCwd = canonicalPath(parsed.cwd)
            let underRoot = canonRoots.contains { canonCwd == $0 || canonCwd.hasPrefix($0 + "/") }
            guard underRoot else { continue }   // mangled-prefix false positive -> drop
            guard seen.insert(parsed.cwd + "\u{0}" + parsed.id).inserted else { continue }
            rows.append(ClaudeSession(id: parsed.id, cwd: parsed.cwd, title: parsed.title,
                                      lastActivity: cand.mtime, accountName: cand.account,
                                      gitBranch: parsed.gitBranch))
            if rows.count >= limit { break }
        }
        return rows
    }

    /// All recent sessions across ALL accounts with NO project/root filter — the
    /// disk-wide scanner that makes every recently-used Claude session discoverable
    /// regardless of whether it was opened through grove.
    ///
    /// Unlike `recentSessions(underRoots:accounts:limit:)`, this method:
    ///   - Does NOT filter by project root — every `projects/<dir>` is scanned.
    ///   - Applies a recency cap: only transcripts whose mtime >= now - sinceDays*86400
    ///     are considered (bounds the scan to the recent window).
    ///   - Still sorts newest-first, deduplicates by (cwd, sessionId), and caps at
    ///     `limit` exactly like the sibling method.
    ///   - Uses the same `cachedParse` mtime cache to bound parse work.
    ///
    /// The injected `now` keeps the method pure/deterministic — no `Date()` inside.
    public func allRecentSessions(accounts: [AccountConfig], limit: Int,
                                  sinceDays: Int, now: Date) -> [ClaudeSession] {
        guard limit > 0 else { return [] }
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(sinceDays) * 86400)

        struct Candidate { let path: String; let mtime: Date; let account: String }
        var candidates: [Candidate] = []
        for account in accounts {
            let projectsDir = expandTilde(account.configDir) + "/projects"
            guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { continue }
            for dir in dirs {
                let dirPath = projectsDir + "/" + dir
                guard let names = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
                for name in names where name.hasSuffix(".jsonl") {
                    let path = dirPath + "/" + name
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
                          let attrs = try? fm.attributesOfItem(atPath: path),
                          let mtime = attrs[.modificationDate] as? Date else { continue }
                    // Recency cap: skip transcripts older than the cutoff.
                    guard mtime >= cutoff else { continue }
                    candidates.append(Candidate(path: path, mtime: mtime, account: account.name))
                }
            }
        }
        candidates.sort { $0.mtime > $1.mtime }

        var rows: [ClaudeSession] = []
        var seen = Set<String>()
        let budget = limit * 4 + 8
        for cand in candidates.prefix(budget) {
            guard let parsed = cachedParse(path: cand.path, mtime: cand.mtime) else { continue }
            guard seen.insert(parsed.cwd + "\u{0}" + parsed.id).inserted else { continue }
            rows.append(ClaudeSession(id: parsed.id, cwd: parsed.cwd, title: parsed.title,
                                      lastActivity: cand.mtime, accountName: cand.account,
                                      gitBranch: parsed.gitBranch))
            if rows.count >= limit { break }
        }
        return rows
    }

    private func cachedParse(path: String, mtime: Date) -> ParsedSession? {
        cacheLock.lock()
        if let entry = sessionCache[path], entry.mtime == mtime {
            let parsed = entry.parsed
            cacheLock.unlock()
            return parsed
        }
        cacheLock.unlock()
        let parsed = ClaudeService.parseSessionFile(path: path)
        cacheLock.lock()
        sessionCache[path] = (mtime: mtime, parsed: parsed)
        cacheLock.unlock()
        return parsed
    }

    private static func parseSessionFile(path: String) -> ParsedSession? {
        guard
            let data = FileManager.default.contents(atPath: path),
            let text = String(data: data, encoding: .utf8)
        else { return nil }

        var fileCwd: String?
        var sessionId: String?
        var gitBranch: String?
        var sawFirstUserRecord = false
        var aiTitle: String?
        var fallbackTitle: String?

        for line in text.split(whereSeparator: \.isNewline) {
            guard
                let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8)))
                    as? [String: Any]
            else { continue }                       // unparseable line: skip, keep going
            if fileCwd == nil, let recordCwd = object["cwd"] as? String {
                fileCwd = recordCwd                 // first record carrying "cwd" wins
            }
            let type = object["type"] as? String
            if type == "user" {
                if sessionId == nil { sessionId = object["sessionId"] as? String }
                if !sawFirstUserRecord {
                    sawFirstUserRecord = true
                    gitBranch = object["gitBranch"] as? String
                }
                if fallbackTitle == nil,
                   (object["userType"] as? String) == "external",
                   let message = object["message"] as? [String: Any],
                   let textContent = extractText(message["content"]),
                   !textContent.isEmpty {
                    fallbackTitle = String(textContent.prefix(80))
                }
            } else if type == "ai-title" {
                if let title = object["aiTitle"] as? String { aiTitle = title }  // LAST one wins
            }
        }

        guard let id = sessionId, let cwd = fileCwd else { return nil }
        return ParsedSession(id: id, cwd: cwd, title: aiTitle ?? fallbackTitle, gitBranch: gitBranch)
    }

    /// User message content is either a plain string or an array of content blocks;
    /// only "text" blocks contribute to the fallback title.
    private static func extractText(_ content: Any?) -> String? {
        if let string = content as? String { return string }
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            if !texts.isEmpty { return texts.joined(separator: " ") }
        }
        return nil
    }

    // MARK: - Live processes

    /// Injectable for tests. Default: pid is alive AND its command line mentions "claude"
    /// (sessions/<pid>.json files can go stale after crashes; pids get reused).
    internal var processValidator: (Int32) -> Bool = ClaudeService.defaultProcessValidator

    /// Live Claude processes of `account`: `<configDir>/sessions/<pid>.json` records
    /// whose pid passes `processValidator`. Malformed JSON files are skipped.
    /// Sorted by pid ascending for deterministic output.
    public func liveProcesses(account: AccountConfig) -> [LiveProcess] {
        let fm = FileManager.default
        let dir = expandTilde(account.configDir) + "/sessions"
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var result: [LiveProcess] = []
        for name in names where name.hasSuffix(".json") {
            let path = dir + "/" + name
            guard
                let data = fm.contents(atPath: path),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let pidValue = object["pid"] as? Int,
                let pid = Int32(exactly: pidValue),
                let sessionId = object["sessionId"] as? String,
                let cwd = object["cwd"] as? String,
                let status = object["status"] as? String
            else { continue }
            guard processValidator(pid) else { continue }
            let startedAt = (object["startedAt"] as? String).flatMap(gitISODate)
            result.append(LiveProcess(pid: pid, sessionId: sessionId, cwd: cwd,
                                      status: status, accountName: account.name,
                                      startedAt: startedAt))
        }
        return result.sorted { $0.pid < $1.pid }
    }

    /// Live Claude sessions discovered from the PROCESS TABLE. Current Claude Code
    /// builds don't always write `sessions/<pid>.json` records (that dir is often
    /// empty), so a resumed session would otherwise read as "closed" even though
    /// `claude --resume <id>` is clearly running. We scan `ps` for those processes
    /// and recover the session id from the command line.
    ///
    /// `ps` alone can't see network-bound generation, so a quiet session reads as
    /// "idle" → the UI shows "waiting" (finished its turn, ready for your next
    /// prompt) rather than "closed". When there IS clear CPU use anywhere in the
    /// process group (a turn, tools, or a subagent), the aggregated subtree CPU is
    /// ≥ busyCPUThreshold and status is "busy" → running.
    /// cwd is empty (callers join by sessionId); accountName is empty.
    /// Deduped by sessionId. Merged AFTER `liveProcesses` so a real status record,
    /// when present, wins.
    public func liveProcessesFromTable() -> [LiveProcess] {
        let listing = Self.runProcessListing()
        // A second `ps` snapshot (pid,ppid,%cpu) for the WHOLE table, so we can roll
        // each claude pid's CPU up over its process GROUP. When a session delegates
        // to SUBAGENTS the main claude process BLOCKS (near-0 %CPU) while its child
        // processes do the work — measuring only the parent's own %CPU would misread
        // an actively-working session as idle → "waiting". Aggregating the subtree
        // fixes that. (LC_ALL=C is forced in runProcess so %cpu always uses a dot.)
        let cpuTree = Self.parseProcessTree(Self.runProcessTreeListing())
        var result: [LiveProcess] = []
        var seen = Set<String>()
        for line in listing.split(separator: "\n") {
            guard let (pid, ownCPU, command) = Self.parsePidCpuCommand(String(line)),
                  command.contains("claude") else { continue }
            // Roll the parent's own %CPU up with all of its descendants' (subagents,
            // tool subprocesses). If the tree snapshot is missing this pid, fall back
            // to its own %CPU from the command listing.
            let cpu = cpuTree[pid] == nil ? ownCPU : Self.subtreeCPU(of: pid, in: cpuTree)
            // We still can't see "generating" from outside (it's network-bound, low
            // CPU, indistinguishable from idle) — that limitation is unchanged and not
            // fixable from outside the process. But clear CPU use ANYWHERE in the
            // process group means the session is actively executing (a turn, tools, or
            // a subagent) → "busy" → running; otherwise it's alive-but-quiet → "idle"
            // → waiting (ready for input).
            let status = cpu >= Self.busyCPUThreshold ? "busy" : "idle"
            if let sessionId = Self.sessionId(in: command) {
                guard !seen.contains(sessionId) else { continue }
                seen.insert(sessionId)
                result.append(LiveProcess(pid: pid, sessionId: sessionId, cwd: "",
                                          status: status, accountName: "", startedAt: nil))
            } else if Self.isBareClaudeCommand(command), let cwd = Self.processCwd(pid) {
                // A FRESH session (no --resume id in argv, e.g. "New Claude"). It
                // can't be matched by session id, so carry its working directory —
                // callers join it to a recent session by cwd so it isn't read as
                // "closed" (which would let a tap spawn a corrupting duplicate).
                result.append(LiveProcess(pid: pid, sessionId: "", cwd: cwd,
                                          status: status, accountName: "", startedAt: nil))
            }
        }
        return result.sorted { $0.pid < $1.pid }
    }

    /// THE single source of truth for live sessions across `accounts`: each
    /// account's `sessions/<pid>.json` records (real busy/waiting/idle status when
    /// present) UNIONed with the process-table scan (resumed + fresh sessions, which
    /// the now-usually-empty records dir misses), deduped by sessionId. Every UI
    /// surface and the CLI route through this so the Projects tab, the Claude tab,
    /// the Workspaces badges, and the Accounts cards can never disagree on liveness.
    /// Runs the process-table scan ONCE (not per account).
    public func allLiveProcesses(accounts: [AccountConfig]) -> [LiveProcess] {
        Self.mergeLive(fileRecords: accounts.flatMap { liveProcesses(account: $0) },
                       table: liveProcessesFromTable())
    }

    /// Union of file records (which carry the REAL busy/waiting status — they win on
    /// a sessionId tie) and process-table entries (fill the gaps), deduped by
    /// sessionId. Fresh entries (empty sessionId, cwd-carried) are all kept — EXCEPT
    /// when the same PID already came in as a file record: a bare `claude` that has
    /// written its statusline record surfaces twice (once with its real id from the
    /// record, once as a fresh empty-id table row for the same pid), so we must drop
    /// the fresh duplicate or the one process is counted twice. Pure.
    static func mergeLive(fileRecords: [LiveProcess], table: [LiveProcess]) -> [LiveProcess] {
        var result: [LiveProcess] = []
        var seen = Set<String>()
        var seenPids = Set<Int32>()
        for p in fileRecords where !p.sessionId.isEmpty && !seen.contains(p.sessionId) {
            result.append(p)
            seen.insert(p.sessionId)
            seenPids.insert(p.pid)
        }
        for p in table {
            if p.sessionId.isEmpty {
                guard !seenPids.contains(p.pid) else { continue }   // same pid already a file record
                result.append(p)                                    // fresh (cwd-carried)
                seenPids.insert(p.pid)
            } else if !seen.contains(p.sessionId) {
                result.append(p)
                seen.insert(p.sessionId)
                seenPids.insert(p.pid)
            }
        }
        return result.sorted { $0.pid < $1.pid }
    }

    /// True for the claude CLI launched WITHOUT --resume (a fresh session): the
    /// executable basename is exactly "claude" and there's no resume flag. Excludes
    /// the cmux wrapper scripts (basename zsh/bash) and our own ps/grep lines.
    static func isBareClaudeCommand(_ command: String) -> Bool {
        // A `--session-id`/`--resume` process HAS an id — it is NOT a fresh, ID-less
        // session, so it must carry its id (joined by id), never an anonymous cwd row.
        guard !command.contains("--resume"), !command.contains("--session-id") else { return false }
        let first = command.split(separator: " ").first.map(String.init) ?? ""
        return (first as NSString).lastPathComponent == "claude"
    }

    /// A process's current working directory via `lsof` (claude does NOT keep its
    /// transcript file open, so the cwd is the only external link to a fresh
    /// session). Called only for the rare bare-claude pid. nil on failure.
    static func processCwd(_ pid: Int32) -> String? {
        let out = runProcess("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    /// CPU% at/above which a live session is treated as actively running. The
    /// observed split is stark (busy ~18%+, idle ≤0.3%), so a moderate threshold
    /// avoids false "running" from the decaying ps average.
    static let busyCPUThreshold = 9.0

    /// The controlling tty (e.g. "/dev/ttys025") of a live `claude --resume <id>`
    /// process, for focusing its Terminal.app tab. nil when no such process exists.
    public func ttyForSession(_ sessionId: String) -> String? {
        for line in Self.runTtyListing().split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            let tty = String(trimmed[..<space])
            let command = String(trimmed[trimmed.index(after: space)...])
            guard command.contains("claude"), Self.sessionId(in: command) == sessionId,
                  tty != "??" else { continue }
            return tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
        }
        return nil
    }

    /// Parses "  <pid> <%cpu> <command…>" from `ps`. nil on malformed lines.
    static func parsePidCpuCommand(_ raw: String) -> (pid: Int32, cpu: Double, command: String)? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard let s1 = line.firstIndex(of: " "), let pid = Int32(line[..<s1]) else { return nil }
        let afterPid = line[line.index(after: s1)...].drop { $0 == " " }
        guard let s2 = afterPid.firstIndex(of: " ") else { return nil }
        let cpu = Double(afterPid[..<s2]) ?? 0
        let command = String(afterPid[afterPid.index(after: s2)...])
        return (pid, cpu, command)
    }

    /// A pid → (ppid, own %cpu) map, used to roll a claude session's CPU up over its
    /// whole process GROUP (see `subtreeCPU`). Built from one `ps -axo pid=,ppid=,%cpu=`
    /// snapshot. Malformed lines are skipped; a duplicate pid keeps the first.
    static func parseProcessTree(_ listing: String) -> [Int32: (ppid: Int32, cpu: Double)] {
        var map: [Int32: (ppid: Int32, cpu: Double)] = [:]
        for raw in listing.split(separator: "\n") {
            guard let (pid, ppid, cpu) = parsePidPpidCpu(String(raw)) else { continue }
            if map[pid] == nil { map[pid] = (ppid, cpu) }
        }
        return map
    }

    /// Parses "  <pid> <ppid> <%cpu>" from `ps -axo pid=,ppid=,%cpu=`. nil on
    /// malformed lines. %cpu uses a dot decimal (runProcess forces LC_ALL=C).
    static func parsePidPpidCpu(_ raw: String) -> (pid: Int32, ppid: Int32, cpu: Double)? {
        let fields = raw.split(whereSeparator: { $0 == " " })
        guard fields.count >= 3,
              let pid = Int32(fields[0]),
              let ppid = Int32(fields[1]),
              let cpu = Double(fields[2]) else { return nil }
        return (pid, ppid, cpu)
    }

    /// Total %CPU of `pid`'s process GROUP: its own %cpu plus that of every descendant
    /// (children, grandchildren — subagents and tool subprocesses), summed iteratively
    /// over a children index derived from `tree`. Cycle-guarded by a visited set so a
    /// malformed ppid loop can't spin. A pid absent from `tree` contributes 0. Pure.
    static func subtreeCPU(of pid: Int32, in tree: [Int32: (ppid: Int32, cpu: Double)]) -> Double {
        var children: [Int32: [Int32]] = [:]
        for (child, info) in tree { children[info.ppid, default: []].append(child) }
        var total = 0.0
        var visited: Set<Int32> = []
        var stack: [Int32] = [pid]
        while let current = stack.popLast() {
            guard visited.insert(current).inserted else { continue }   // cycle guard
            total += tree[current]?.cpu ?? 0
            if let kids = children[current] { stack.append(contentsOf: kids) }
        }
        return total
    }

    /// Extracts the session id from a `claude --resume <uuid>` or `claude --session-id
    /// <uuid>` command line (cmux launches with `--session-id`). nil for processes
    /// carrying neither flag (a truly bare new session can't be mapped to an id) and
    /// for the cmux wrapper scripts (whose path mentions claude but lacks either flag).
    static func sessionId(in command: String) -> String? {
        // Accept `--resume <id>`/`--resume=<id>` AND `--session-id <id>`/`--session-id=<id>`
        // (cmux launches Claude with `--session-id`). The equals form would otherwise
        // leave the session unmatchable (read as fresh); and an unrecognized
        // `--session-id` makes the process an empty-id, cwd-only table row that colors
        // every closed session sharing the directory as running (the stuck-running bug).
        guard let range = command.range(of: "--resume ") ?? command.range(of: "--resume=")
            ?? command.range(of: "--session-id ") ?? command.range(of: "--session-id=")
        else { return nil }
        let token = command[range.upperBound...].prefix { !$0.isWhitespace }
        let id = String(token)
        return id.count == 36 && id.allSatisfy { $0.isHexDigit || $0 == "-" } ? id : nil
    }

    private static func runProcessListing() -> String { runProcess("/bin/ps", ["-axo", "pid=,%cpu=,command="]) }
    private static func runProcessTreeListing() -> String { runProcess("/bin/ps", ["-axo", "pid=,ppid=,%cpu="]) }
    private static func runTtyListing() -> String { runProcess("/bin/ps", ["-axo", "tty=,command="]) }

    static func runProcess(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Force the C locale so `ps` prints %cpu with a DOT decimal separator
        // regardless of the user's locale (ru_RU/de_DE/etc. print "9,5", which
        // Double() can't parse → every session would read as idle/waiting).
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Public seam so callers (AppState's concurrency guard) can inject a liveness
    /// predicate without reaching the internal `processValidator`. Returns a
    /// configured instance.
    public func withProcessValidator(_ validator: @escaping (Int32) -> Bool) -> ClaudeService {
        let copy = ClaudeService()
        copy.processValidator = validator
        return copy
    }

    internal static func defaultProcessValidator(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "command=", "-p", String(pid)]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let command = String(data: data, encoding: .utf8) ?? ""
        return command.contains("claude")
    }

    // MARK: - Launch commands

    /// Effort levels accepted by `claude --effort` — the full set per `claude
    /// --help` (low, medium, high, xhigh, max). The single source of truth for the
    /// effort pickers, so xhigh/max can't be missed.
    public static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    /// Candidate install locations for the claude CLI, checked in order.
    /// Injectable for tests.
    static var claudeCandidatePaths: [String] = [
        NSHomeDirectory() + "/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    /// Absolute path to the claude binary when one of the known install
    /// locations exists, else bare "claude" (PATH lookup). Resolving an
    /// absolute path makes launch commands immune to shells whose init files
    /// never add ~/.local/bin to PATH (fresh cmux workspaces, GUI-spawned
    /// shells) — the recurring "claude not found in PATH" failure.
    public static func claudeExecutable() -> String {
        let fm = FileManager.default
        for path in claudeCandidatePaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        return "claude"
    }

    /// Shell command string for cmux `--command`. Default account (expanded configDir
    /// == $HOME/.claude) needs no env prefix; custom accounts get CLAUDE_CONFIG_DIR.
    /// Optional `model`/`effort` append `--model <id>` / `--effort <level>` (spec §C.6,
    /// applied at launch only — a running process can't be re-modeled, NG1).
    /// `skipPermissions` appends `--dangerously-skip-permissions` (per-project, for
    /// fully-autonomous agents). The binary path, config dir, resume id, model and
    /// effort are single-quote shell-quoted.
    public static func launchCommand(account: AccountConfig, resume sessionId: String? = nil,
                                     model: String? = nil, effort: String? = nil,
                                     skipPermissions: Bool = false) -> String {
        let dir = expandTilde(account.configDir)
        let isDefaultAccount = dir == NSHomeDirectory() + "/.claude"
        let claude = shellQuote(claudeExecutable())
        var command = isDefaultAccount ? claude : "CLAUDE_CONFIG_DIR=\(shellQuote(dir)) \(claude)"
        // Guard on non-empty so an empty value (e.g. a hand-edited config with
        // model: "") is treated like nil instead of emitting `--model ''`.
        if let sessionId, !sessionId.isEmpty { command += " --resume \(shellQuote(sessionId))" }
        if let model, !model.isEmpty { command += " --model \(shellQuote(model))" }
        if let effort, !effort.isEmpty { command += " --effort \(shellQuote(effort))" }
        // A literal flag (no value) — append last so it reads naturally in logs.
        if skipPermissions { command += " --dangerously-skip-permissions" }
        return command
    }
}
