import Foundation

public struct MirrorAccount: Sendable, Equatable {
    public let key: String        // accountKey(configDir)
    public let configDir: String  // expanded, no trailing slash
    public init(key: String, configDir: String) { self.key = key; self.configDir = configDir }
}

public struct RetentionPolicy: Sendable {
    public let maxDays: Int       // 0 = no age cap
    public let maxBytes: Int64    // 0 = no size cap
    public init(maxDays: Int, maxBytes: Int64) { self.maxDays = maxDays; self.maxBytes = maxBytes }
}

public struct ReconcileReport: Sendable, Equatable {
    public var linked:   [String] = []
    public var restored: [String] = []
    public var evicted:  [String] = []
    public var issues:   [String] = []
    public init() {}
}

/// Injectable filesystem ops so tests can force the cross-volume fallback.
public struct FileOps: Sendable {
    public var hardlink:     @Sendable (_ src: String, _ dst: String) throws -> Void
    public var copyFallback: @Sendable (_ src: String, _ dst: String) throws -> Void
    public init(hardlink: @escaping @Sendable (String, String) throws -> Void,
                copyFallback: @escaping @Sendable (String, String) throws -> Void) {
        self.hardlink = hardlink; self.copyFallback = copyFallback
    }
    public static let live = FileOps(
        hardlink:     { try FileManager.default.linkItem(atPath: $0, toPath: $1) },
        copyFallback: { try FileManager.default.copyItem(atPath: $0, toPath: $1) }
    )
}

/// Hardlink safety-net for Claude session transcripts (spec 2026-07-08). Same
/// conventions as `SharedSessionStore`: struct over `FileManager`, explicit string
/// paths (never hardcodes ~/.claude), idempotent, never throws out of `reconcile`.
public struct TranscriptMirror: Sendable {
    private let ops: FileOps
    public init(fileOps: FileOps = .live) { self.ops = fileOps }

    public static func mirrorRoot(canonicalDir: String) -> String { canonicalDir + "/grove/transcripts" }

    struct EntryRef: Hashable { let accountKey: String; let encodedCwd: String; let file: String }
    struct EntryState { var livePath: String?; var mirrorPath: String? }

    @discardableResult
    public func reconcile(accounts: [MirrorAccount], canonicalDir: String,
                          policy: RetentionPolicy, now: Date = Date()) -> ReconcileReport {
        let fm = FileManager.default
        var report = ReconcileReport()
        let mirrorRoot = Self.mirrorRoot(canonicalDir: canonicalDir)
        var entries: [EntryRef: EntryState] = [:]

        // 1. live transcripts (ground truth)
        for acc in accounts {
            let projects = acc.configDir + "/projects"
            for cwd in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
                let cwdDir = projects + "/" + cwd
                for name in (try? fm.contentsOfDirectory(atPath: cwdDir)) ?? [] {
                    guard name.hasSuffix(".jsonl") else { continue }
                    let live = cwdDir + "/" + name
                    if (try? fm.destinationOfSymbolicLink(atPath: live)) != nil { continue } // skip symlinks
                    entries[EntryRef(accountKey: acc.key, encodedCwd: cwd, file: name), default: EntryState()].livePath = live
                }
            }
        }
        // 2. existing mirror entries
        for key in (try? fm.contentsOfDirectory(atPath: mirrorRoot)) ?? [] {
            let keyDir = mirrorRoot + "/" + key
            for cwd in (try? fm.contentsOfDirectory(atPath: keyDir)) ?? [] {
                let cwdDir = keyDir + "/" + cwd
                for name in (try? fm.contentsOfDirectory(atPath: cwdDir)) ?? [] {
                    guard name.hasSuffix(".jsonl") else { continue }
                    entries[EntryRef(accountKey: key, encodedCwd: cwd, file: name), default: EntryState()].mirrorPath = cwdDir + "/" + name
                }
            }
        }

        let configDirByKey = Dictionary(accounts.map { ($0.key, $0.configDir) }, uniquingKeysWith: { a, _ in a })

        // size cap: scan mirror-only inodes (nlink == 1) BEFORE the reconcile loop so
        // that we measure the true cost before any restoration inflates the link count.
        var sizeEvicted: Set<String> = []
        if policy.maxBytes > 0 {
            var mirrorOnly: [(path: String, mtime: Date, size: Int64)] = []
            for key in (try? fm.contentsOfDirectory(atPath: mirrorRoot)) ?? [] {
                let keyDir = mirrorRoot + "/" + key
                for cwd in (try? fm.contentsOfDirectory(atPath: keyDir)) ?? [] {
                    let cwdDir = keyDir + "/" + cwd
                    for name in (try? fm.contentsOfDirectory(atPath: cwdDir)) ?? [] where name.hasSuffix(".jsonl") {
                        let p = cwdDir + "/" + name
                        if (nlink(p) ?? 2) == 1, let m = mtime(p) { mirrorOnly.append((p, m, size(p))) }
                    }
                }
            }
            var total = mirrorOnly.reduce(Int64(0)) { $0 + $1.size }
            for e in mirrorOnly.sorted(by: { $0.mtime < $1.mtime }) where total > policy.maxBytes {
                try? fm.removeItem(atPath: e.path); report.evicted.append(e.path); total -= e.size
                sizeEvicted.insert(e.path)
            }
        }

        for (ref, st) in entries {
            let mp = st.mirrorPath ?? (mirrorRoot + "/\(ref.accountKey)/\(ref.encodedCwd)/\(ref.file)")
            // skip entries whose mirror was just size-evicted
            if let existing = st.mirrorPath, sizeEvicted.contains(existing) { continue }
            let refMtime = st.livePath.flatMap(mtime) ?? st.mirrorPath.flatMap(mtime)
            let ageDays = refMtime.map { now.timeIntervalSince($0) / 86400 } ?? 0
            let withinAge = policy.maxDays == 0 || ageDays <= Double(policy.maxDays)

            guard withinAge else {
                if let existing = st.mirrorPath { try? fm.removeItem(atPath: existing); report.evicted.append(existing) }
                continue
            }

            if let live = st.livePath {
                if st.mirrorPath == nil {
                    placeMirror(src: live, dst: mp, report: &report)
                } else if inode(live) != inode(mp) {
                    try? fm.removeItem(atPath: mp); placeMirror(src: live, dst: mp, report: &report)
                }
            } else if st.mirrorPath != nil {
                guard let cfg = configDirByKey[ref.accountKey] else {
                    report.issues.append("mirror \(ref.file): account \(ref.accountKey) unknown"); continue
                }
                let live = cfg + "/projects/\(ref.encodedCwd)/\(ref.file)"
                do {
                    try fm.createDirectory(atPath: (live as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try ops.hardlink(mp, live)
                    report.restored.append(live)
                } catch { report.issues.append("restore \(ref.file): \(error.localizedDescription)") }
            }
        }
        return report
    }

    private func placeMirror(src: String, dst: String, report: inout ReconcileReport) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        do { try ops.hardlink(src, dst); report.linked.append(dst) }
        catch {
            do { try ops.copyFallback(src, dst); report.issues.append("cross-volume snapshot (copy): \(dst)") }
            catch { report.issues.append("mirror failed \(dst): \(error.localizedDescription)") }
        }
    }

    /// Permanent delete: unlink the mirror(s) for `sessionId` AND every live
    /// transcript path across `accounts`. After this, `reconcile` finds no mirror
    /// and will not restore it.
    public func purge(sessionId: String, accounts: [MirrorAccount], canonicalDir: String) throws {
        let fm = FileManager.default
        let mirrorRoot = Self.mirrorRoot(canonicalDir: canonicalDir)
        let file = sessionId + ".jsonl"
        // mirror side
        for key in (try? fm.contentsOfDirectory(atPath: mirrorRoot)) ?? [] {
            let keyDir = mirrorRoot + "/" + key
            for cwd in (try? fm.contentsOfDirectory(atPath: keyDir)) ?? [] {
                let p = keyDir + "/\(cwd)/\(file)"
                if fm.fileExists(atPath: p) { try fm.removeItem(atPath: p) }
            }
        }
        // live side
        for acc in accounts {
            let projects = acc.configDir + "/projects"
            for cwd in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
                let p = projects + "/\(cwd)/\(file)"
                if fm.fileExists(atPath: p) { try fm.removeItem(atPath: p) }
            }
        }
    }

    func inode(_ path: String) -> Int? { (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int }
    func nlink(_ path: String) -> Int? { (try? FileManager.default.attributesOfItem(atPath: path))?[.referenceCount] as? Int }
    func size(_ path: String) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0 }
    func mtime(_ path: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }
}
