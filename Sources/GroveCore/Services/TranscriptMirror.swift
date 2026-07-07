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

        for (ref, st) in entries {
            let mp = st.mirrorPath ?? (mirrorRoot + "/\(ref.accountKey)/\(ref.encodedCwd)/\(ref.file)")
            // within-age protect: for now, only the link step (live present, mirror missing)
            if let live = st.livePath, st.mirrorPath == nil {
                placeMirror(src: live, dst: mp, report: &report)
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

    func inode(_ path: String) -> Int? { (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int }
    func nlink(_ path: String) -> Int? { (try? FileManager.default.attributesOfItem(atPath: path))?[.referenceCount] as? Int }
    func size(_ path: String) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0 }
    func mtime(_ path: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }
}
