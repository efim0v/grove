import Foundation

/// Symlink-based shared session store (spec §5, decisions D1/D2). The canonical
/// store is the default `~/.claude` account; additional accounts link INTO it so
/// a conversation is one physical artifact reachable from every account. This
/// type takes explicit STRING paths for both the canonical dir and an account
/// dir — it NEVER hardcodes `~/.claude` — so tests inject temp dirs and the real
/// store is never touched. A `struct` over `FileManager`: no stored state.
///
/// Two store shapes (spec §2):
/// - wholesale, UUID-keyed: `file-history`, `tasks`, `session-env` — the WHOLE
///   dir is symlinked (UUID entries → collision-free).
/// - cwd-keyed: `projects/<mangle(cwd)>` — symlinked PER WORKSPACE.
///
/// Every mutation is non-destructive: it migrates by MOVING entries into canonical
/// only when canonical lacks them, backs up the account's real dir before replacing
/// it with a symlink, and is idempotent + reversible (`unlink`).
public struct SharedSessionStore: Sendable {
    public init() {}

    /// UUID-keyed stores shared wholesale. The single source of truth — adding a
    /// future Claude store is a one-line change here (and `verify` flags unknown ones).
    public static let wholesaleDirs: [String] = ["file-history", "tasks", "session-env"]

    /// Known top-level dirs that are NOT shared session stores (cwd-keyed, local, or
    /// Grove's own backup). The single source of truth for `verify`'s allowlist.
    /// Any UNKNOWN new top-level dir surfacing as a banner is INTENTIONAL — so a
    /// future Claude store dir gets noticed instead of silently diverging.
    public static let knownNonSharedDirs: Set<String> =
        ["projects", "sessions", "shell-snapshots", "todos", "statsig", "grove-backup"]

    /// Links every wholesale dir of `accountDir` into `canonicalDir` (migrate-merge
    /// existing entries with a backup, then replace with a symlink). Idempotent.
    /// Returns human-readable log lines (one per dir). Throws only on unexpected
    /// FileManager errors.
    @discardableResult
    public func ensureLinked(accountDir: String, canonicalDir: String) throws -> [String] {
        let fm = FileManager.default
        let backupLabel = "link-" + Self.timestamp()
        var log: [String] = []
        for name in Self.wholesaleDirs {
            log.append(try linkOneWholesale(name: name,
                                            accountDir: accountDir,
                                            canonicalDir: canonicalDir,
                                            backupLabel: backupLabel,
                                            fm: fm))
        }
        return log
    }

    /// Ensures `accountDir/projects/<mangledCwd>` is a symlink into the same path
    /// under `canonicalDir` (migrate-merge if it is a real dir). Returns true when
    /// it created or changed the link, false when it was already correct.
    @discardableResult
    public func ensureWorkspaceLinked(accountDir: String, canonicalDir: String,
                                      mangledCwd: String) throws -> Bool {
        let fm = FileManager.default
        let name = "projects/" + mangledCwd
        let accountPath = accountDir + "/" + name
        let canonicalPath = canonicalDir + "/" + name

        // Ensure the parent projects dirs exist on both sides so the per-cwd leaf
        // can be symlinked beside any other already-real per-cwd dirs.
        try fm.createDirectory(atPath: canonicalDir + "/projects",
                               withIntermediateDirectories: true)
        try fm.createDirectory(atPath: accountDir + "/projects",
                               withIntermediateDirectories: true)
        // Canonical leaf must exist as a real dir so the symlink resolves.
        try fm.createDirectory(atPath: canonicalPath, withIntermediateDirectories: true)

        // Already a correct symlink → no change.
        if let dest = try? fm.destinationOfSymbolicLink(atPath: accountPath), dest == canonicalPath {
            return false
        }

        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: accountPath, isDirectory: &isDir)
        let isSymlink = (try? fm.attributesOfItem(atPath: accountPath)[.type] as? FileAttributeType)
            == FileAttributeType.typeSymbolicLink

        if isSymlink {
            // A symlink pointing somewhere else → repoint.
            try fm.removeItem(atPath: accountPath)
            try fm.createSymbolicLink(atPath: accountPath, withDestinationPath: canonicalPath)
            return true
        } else if exists && isDir.boolValue {
            // A real dir → migrate-merge then back up then symlink.
            let backupLabel = "workspace-" + Self.timestamp()
            let backupDir = accountDir + "/grove-backup/" + backupLabel
            try migrateMergeAndLink(accountPath: accountPath,
                                    canonicalPath: canonicalPath,
                                    backupDir: backupDir,
                                    backupName: mangledCwd,
                                    fm: fm)
            return true
        } else {
            // Absent → create the symlink.
            try fm.createSymbolicLink(atPath: accountPath, withDestinationPath: canonicalPath)
            return true
        }
    }

    /// Self-check across linked accounts: a wholesale dir that is a broken symlink,
    /// a wholesale dir that is still a real dir (never linked), and any UNKNOWN
    /// sessionId-keyed store directory that isn't in `wholesaleDirs` (so a future
    /// Claude store surfaces as a banner instead of silently diverging). Returns
    /// issue strings (empty = healthy). Never throws — a verify failure must not
    /// crash startup.
    public func verify(accountDirs: [String], canonicalDir: String) -> [String] {
        let fm = FileManager.default
        var issues: [String] = []
        for accountDir in accountDirs {
            for name in Self.wholesaleDirs {
                let path = accountDir + "/" + name
                if let dest = try? fm.destinationOfSymbolicLink(atPath: path) {
                    // It is a symlink — check the target exists on disk.
                    if !fm.fileExists(atPath: dest) {
                        issues.append("\(accountDir): \(name) symlink is broken")
                    }
                } else {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue {
                        issues.append("\(accountDir): \(name) is a real dir, not shared (run Link)")
                    }
                    // Absent → not an issue.
                }
            }
            let entries = (try? fm.contentsOfDirectory(atPath: accountDir)) ?? []
            for entry in entries {
                if entry.hasPrefix(".") { continue }
                if Self.wholesaleDirs.contains(entry) { continue }
                if Self.knownNonSharedDirs.contains(entry) { continue }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: accountDir + "/" + entry, isDirectory: &isDir), isDir.boolValue {
                    issues.append("\(accountDir): unknown session store '\(entry)' (not in wholesaleDirs)")
                }
            }
        }
        return issues
    }

    /// Reverses `ensureLinked` for one account: replaces each wholesale symlink with
    /// a real dir whose contents are copied back from canonical (the account keeps
    /// its history; canonical stays intact for other accounts). Idempotent. Per-
    /// workspace `projects` symlinks are left as-is (harmless dangling is impossible —
    /// they point at canonical which still exists).
    public func unlink(accountDir: String, canonicalDir: String) throws {
        let fm = FileManager.default
        for name in Self.wholesaleDirs {
            let accountPath = accountDir + "/" + name
            let canonicalPath = canonicalDir + "/" + name
            guard (try? fm.destinationOfSymbolicLink(atPath: accountPath)) != nil else {
                // Real dir or absent → leave it (idempotent).
                continue
            }
            try fm.removeItem(atPath: accountPath)
            if fm.fileExists(atPath: canonicalPath) {
                try fm.copyItem(atPath: canonicalPath, toPath: accountPath)
            } else {
                try fm.createDirectory(atPath: accountPath, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: - private helpers

    private func linkOneWholesale(name: String, accountDir: String, canonicalDir: String,
                                  backupLabel: String, fm: FileManager) throws -> String {
        let accountPath = accountDir + "/" + name
        let canonicalPath = canonicalDir + "/" + name

        // Ensure canonical exists as a real directory.
        var canonIsDir: ObjCBool = false
        if !(fm.fileExists(atPath: canonicalPath, isDirectory: &canonIsDir) && canonIsDir.boolValue) {
            try fm.createDirectory(atPath: canonicalPath, withIntermediateDirectories: true)
        }

        // Already a correct symlink?
        if let dest = try? fm.destinationOfSymbolicLink(atPath: accountPath) {
            if dest == canonicalPath {
                return "\(name): already linked"
            }
            // A symlink to somewhere else → repoint.
            try fm.removeItem(atPath: accountPath)
            try fm.createSymbolicLink(atPath: accountPath, withDestinationPath: canonicalPath)
            return "\(name): repointed → canonical"
        }

        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: accountPath, isDirectory: &isDir)
        if exists && isDir.boolValue {
            // A real directory → migrate-merge, back up, symlink.
            let backupDir = accountDir + "/grove-backup/" + backupLabel
            let moved = try migrateMergeAndLink(accountPath: accountPath,
                                                canonicalPath: canonicalPath,
                                                backupDir: backupDir,
                                                backupName: name,
                                                fm: fm)
            return "\(name): migrated \(moved) entries, linked"
        } else {
            // Absent → create the symlink.
            try fm.createSymbolicLink(atPath: accountPath, withDestinationPath: canonicalPath)
            return "\(name): linked (was empty)"
        }
    }

    /// Migrate-merges a real `accountPath` directory into `canonicalPath` (moving
    /// only entries canonical lacks), backs up whatever remains under
    /// `backupDir/backupName`, then creates the symlink at `accountPath`. Returns
    /// the number of entries actually moved.
    @discardableResult
    private func migrateMergeAndLink(accountPath: String, canonicalPath: String,
                                     backupDir: String, backupName: String,
                                     fm: FileManager) throws -> Int {
        var moved = 0
        let entries = (try? fm.contentsOfDirectory(atPath: accountPath)) ?? []
        for e in entries {
            let target = canonicalPath + "/" + e
            if !fm.fileExists(atPath: target) {
                try fm.moveItem(atPath: accountPath + "/" + e, toPath: target)
                moved += 1
            }
            // Else: collision — leave canonical's untouched; the account's copy is
            // carried into the backup below.
        }
        // Back up whatever remains of accountPath (conflicting entries or empty shell).
        try fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        let backupLeaf = (backupName as NSString).lastPathComponent
        try fm.moveItem(atPath: accountPath, toPath: backupDir + "/" + backupLeaf)
        // Create the symlink.
        try fm.createSymbolicLink(atPath: accountPath, withDestinationPath: canonicalPath)
        return moved
    }

    private static func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return fmt.string(from: Date())
    }
}
