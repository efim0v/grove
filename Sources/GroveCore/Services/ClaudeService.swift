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

/// Reads Claude Code account identity, session transcripts and (Task 9) live processes
/// from a `CLAUDE_CONFIG_DIR`. A class (not a struct) so it can keep an mtime-keyed
/// parse cache: a jsonl file is re-parsed only when its modification date changes.
public final class ClaudeService {
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
        guard
            let data = FileManager.default.contents(atPath: jsonPath),
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
    /// applied at launch only — a running process can't be re-modeled, NG1). The binary
    /// path, config dir, resume id, model and effort are single-quote shell-quoted.
    public static func launchCommand(account: AccountConfig, resume sessionId: String? = nil,
                                     model: String? = nil, effort: String? = nil) -> String {
        let dir = expandTilde(account.configDir)
        let isDefaultAccount = dir == NSHomeDirectory() + "/.claude"
        let claude = shellQuote(claudeExecutable())
        var command = isDefaultAccount ? claude : "CLAUDE_CONFIG_DIR=\(shellQuote(dir)) \(claude)"
        if let sessionId { command += " --resume \(shellQuote(sessionId))" }
        if let model { command += " --model \(shellQuote(model))" }
        if let effort { command += " --effort \(shellQuote(effort))" }
        return command
    }
}
