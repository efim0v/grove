import Foundation

/// Read-modify-write of a JSON file that a RUNNING `claude` process may be writing
/// at the same moment (`.claude.json`, `settings.json`, the plugin registries).
/// This is what lets a session migrate INTO an account that is in use.
///
/// Three layers, each closing a different hole:
///  1. **Claude's own lock.** Claude Code guards these files with `proper-lockfile`:
///     a `<file>.lock` DIRECTORY whose mtime the holder keeps fresh. We take the same
///     lock, so a cooperating writer waits for us and we wait for it.
///  2. **Compare-before-swap.** The file's identity (inode/size/mtime) is sampled
///     before the read and again right before the rename; any change restarts the
///     merge on the fresh content. Covers writers that don't take the lock.
///  3. **No-op skip.** When the merge changes nothing the file is not touched at
///     all — the common case when a second project moves to an already-set-up account.
///
/// A file that exists but does not parse is NEVER overwritten (it would replace the
/// account's whole config — login included — with just our keys); it is retried and
/// then reported.
public enum HotJSONFile {

    public enum Outcome: Equatable, Sendable {
        case written
        case unchanged
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case lockTimeout(String)
        case unparseable(String)
        case contended(String)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .lockTimeout(let p): return "\(p) is locked by another process — try again"
            case .unparseable(let p): return "\(p) exists but is not valid JSON — left untouched"
            case .contended(let p):   return "\(p) kept changing while merging — try again"
            case .io(let m):          return m
            }
        }
    }

    /// proper-lockfile's default: a lock whose mtime is older than this is abandoned.
    static let staleLockAge: TimeInterval = 10

    /// Applies `transform` to the decoded top-level object (`[:]` when the file is
    /// absent) and swaps the result in atomically. `mode` is applied to the written
    /// file when given; otherwise an existing file's mode is preserved.
    @discardableResult
    public static func update(
        path rawPath: String,
        mode: Int? = nil,
        lockWait: TimeInterval = 3,
        transform: ([String: Any]) -> [String: Any]
    ) throws -> Outcome {
        let fm = FileManager.default
        // Write through a symlink rather than replacing it with a regular file.
        let path = fm.fileExists(atPath: rawPath)
            ? URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path : rawPath
        let parent = (path as NSString).deletingLastPathComponent
        do { try fm.createDirectory(atPath: parent, withIntermediateDirectories: true) }
        catch { throw Failure.io("mkdir \(parent): \(error.localizedDescription)") }

        let lockDir = path + ".lock"
        try acquire(lockDir: lockDir, wait: lockWait, path: path)
        defer { rmdir(lockDir) }

        var parseFailures = 0
        for _ in 0..<8 {
            let before = identity(path)
            var current: [String: Any] = [:]
            if let data = fm.contents(atPath: path), !data.isEmpty {
                guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    // Possibly caught mid-write by a non-atomic writer: look again.
                    parseFailures += 1
                    if parseFailures >= 4 { throw Failure.unparseable(path) }
                    usleep(50_000)
                    continue
                }
                current = parsed
            }

            let merged = transform(current)
            if before != nil || merged.isEmpty, NSDictionary(dictionary: merged).isEqual(to: current) { return .unchanged }

            let outData: Data
            do { outData = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted]) }
            catch { throw Failure.io("encode \(path): \(error.localizedDescription)") }

            let tmp = parent + "/." + (path as NSString).lastPathComponent + ".grove-\(getpid())-\(UUID().uuidString.prefix(8))"
            let perms = mode ?? before.map { Int($0.mode & 0o7777) } ?? 0o600
            guard fm.createFile(atPath: tmp, contents: outData, attributes: [.posixPermissions: perms]) else {
                throw Failure.io("write \(tmp) failed")
            }
            // Someone wrote between our read and now → redo the merge on their content.
            guard identity(path) == before else {
                unlink(tmp)
                continue
            }
            guard rename(tmp, path) == 0 else {
                let message = String(cString: strerror(errno))
                unlink(tmp)
                throw Failure.io("rename → \(path): \(message)")
            }
            return .written
        }
        throw Failure.contended(path)
    }

    // MARK: - Internals

    private struct Identity: Equatable {
        let inode: UInt64
        let size: Int64
        let mtimeSec: Int
        let mtimeNsec: Int
        let mode: UInt16
    }

    private static func identity(_ path: String) -> Identity? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Identity(inode: UInt64(st.st_ino), size: Int64(st.st_size),
                        mtimeSec: st.st_mtimespec.tv_sec, mtimeNsec: st.st_mtimespec.tv_nsec,
                        mode: UInt16(st.st_mode))
    }

    /// proper-lockfile protocol: the lock is `mkdir`; an existing lock dir whose
    /// mtime is older than `staleLockAge` was abandoned by a dead holder and is reclaimed.
    private static func acquire(lockDir: String, wait: TimeInterval, path: String) throws {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            if mkdir(lockDir, 0o755) == 0 { return }
            guard errno == EEXIST else {
                throw Failure.io("lock \(lockDir): \(String(cString: strerror(errno)))")
            }
            var st = stat()
            if stat(lockDir, &st) == 0,
               Date().timeIntervalSince1970 - TimeInterval(st.st_mtimespec.tv_sec) > staleLockAge {
                rmdir(lockDir)
                continue
            }
            if Date() >= deadline { throw Failure.lockTimeout(path) }
            usleep(25_000)
        }
    }
}
