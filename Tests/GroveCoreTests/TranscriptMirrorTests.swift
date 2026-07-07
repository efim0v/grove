import XCTest
@testable import GroveCore

final class TranscriptMirrorTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var canonical: URL!             // ~/.claude analogue
    private let mirror = TranscriptMirror()

    override func setUpWithError() throws {
        root = try Fixture.tempDir("transcript-mirror")
        canonical = root.appendingPathComponent("canonical")
        try fm.createDirectory(at: canonical, withIntermediateDirectories: true)
    }

    /// Writes a live transcript and returns (accountKey, encodedCwd, id, livePath).
    @discardableResult
    private func writeTranscript(configDir: URL, cwd: String, id: String,
                                 _ body: String) throws -> String {
        let dir = configDir.appendingPathComponent("projects/\(cwd)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(id).jsonl")
        try body.write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    private func acct(_ dir: URL) -> MirrorAccount { MirrorAccount(key: accountKey(dir.path), configDir: dir.path) }
    private func policy() -> RetentionPolicy { RetentionPolicy(maxDays: 90, maxBytes: 500 * 1_000_000) }

    private func mirrorPath(_ cwd: String, _ id: String, account: URL) -> String {
        TranscriptMirror.mirrorRoot(canonicalDir: canonical.path)
            + "/\(accountKey(account.path))/\(cwd)/\(id).jsonl"
    }

    func testLinkCreatesHardlinkSharingInode() throws {
        let live = try writeTranscript(configDir: canonical, cwd: "-Users-x-proj", id: "aaaa", "line1\n")
        let report = mirror.reconcile(accounts: [acct(canonical)], canonicalDir: canonical.path, policy: policy())
        let mp = mirrorPath("-Users-x-proj", "aaaa", account: canonical)
        XCTAssertTrue(fm.fileExists(atPath: mp), "mirror not created")
        XCTAssertEqual(inode(live), inode(mp), "mirror must share the inode")
        XCTAssertEqual(report.linked.count, 1)
    }

    func testLinkIsIdempotent() throws {
        try writeTranscript(configDir: canonical, cwd: "-Users-x-proj", id: "aaaa", "line1\n")
        _ = mirror.reconcile(accounts: [acct(canonical)], canonicalDir: canonical.path, policy: policy())
        let second = mirror.reconcile(accounts: [acct(canonical)], canonicalDir: canonical.path, policy: policy())
        XCTAssertEqual(second.linked.count, 0, "second pass should be a no-op")
    }

    func testUnlinkWhileOpenThenRestore() throws {
        // 1. live transcript exists; mirror it.
        let cwd = "-Users-x-proj", id = "bbbb"
        let live = try writeTranscript(configDir: canonical, cwd: cwd, id: id, "line1\n")
        _ = mirror.reconcile(accounts: [acct(canonical)], canonicalDir: canonical.path, policy: policy())
        let mp = mirrorPath(cwd, id, account: canonical)

        // 2. simulate Claude appending AFTER an out-of-band unlink of its own path.
        let fh = FileHandle(forWritingAtPath: live)!
        fh.seekToEndOfFile()
        try fm.removeItem(atPath: live)                 // unlink while the fd is open
        fh.write(Data("line2\n".utf8))                  // process keeps appending to the dead inode
        try fh.close()

        // mirror (same inode) must now hold the FULL transcript incl. post-unlink line
        XCTAssertEqual(try String(contentsOfFile: mp, encoding: .utf8), "line1\nline2\n")
        XCTAssertFalse(fm.fileExists(atPath: live), "live path is gone")

        // 3. next reconcile restores the live path from the mirror
        let report = mirror.reconcile(accounts: [acct(canonical)], canonicalDir: canonical.path, policy: policy())
        XCTAssertTrue(fm.fileExists(atPath: live), "live not restored")
        XCTAssertEqual(try String(contentsOfFile: live, encoding: .utf8), "line1\nline2\n")
        XCTAssertEqual(report.restored.count, 1)
    }

    func testInodeDriftRelinks() throws {
        let cwd = "-Users-x-proj", id = "cccc"
        let live = try writeTranscript(configDir: canonical, cwd: cwd, id: id, "v1\n")
        _ = mirror.reconcile(accounts: [acct(canonical)], canonicalDir: canonical.path, policy: policy())
        let mp = mirrorPath(cwd, id, account: canonical)
        // replace the live file with a brand-new inode (atomic write)
        try "v2\n".write(toFile: live, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(inode(live), inode(mp))
        _ = mirror.reconcile(accounts: [acct(canonical)], canonicalDir: canonical.path, policy: policy())
        XCTAssertEqual(inode(live), inode(mp), "mirror should re-link to the new inode")
        XCTAssertEqual(try String(contentsOfFile: mp, encoding: .utf8), "v2\n")
    }

    // test-local stat helper
    private func inode(_ path: String) -> Int? {
        (try? fm.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int
    }
}
