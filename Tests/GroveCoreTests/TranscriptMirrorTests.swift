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

    private func setMtime(_ path: String, daysAgo: Int, now: Date) throws {
        let d = now.addingTimeInterval(-Double(daysAgo) * 86400)
        try fm.setAttributes([.modificationDate: d], ofItemAtPath: path)
    }

    func testAgeOutDropsMirrorOnlyEntryAndDoesNotRestore() throws {
        let cwd = "-Users-x-proj", id = "dddd"
        let live = try writeTranscript(configDir: canonical, cwd: cwd, id: id, "old\n")
        let now = Date()
        _ = mirror.reconcile(accounts: [acct(canonical)], canonicalDir: canonical.path, policy: policy(), now: now)
        let mp = mirrorPath(cwd, id, account: canonical)
        // become mirror-only + ancient
        try fm.removeItem(atPath: live)
        try setMtime(mp, daysAgo: 200, now: now)
        let report = mirror.reconcile(accounts: [acct(canonical)], canonicalDir: canonical.path,
                                      policy: RetentionPolicy(maxDays: 90, maxBytes: 0), now: now)
        XCTAssertFalse(fm.fileExists(atPath: mp), "aged-out mirror should be evicted")
        XCTAssertFalse(fm.fileExists(atPath: live), "must NOT restore an aged-out entry")
        XCTAssertEqual(report.evicted.count, 1)
        XCTAssertEqual(report.restored.count, 0)
    }

    func testFreshMirrorOnlyEntryIsRestoredNotEvicted() throws {
        let cwd = "-Users-x-proj", id = "eeee"
        let live = try writeTranscript(configDir: canonical, cwd: cwd, id: id, "fresh\n")
        let now = Date()
        _ = mirror.reconcile(accounts: [acct(canonical)], canonicalDir: canonical.path, policy: policy(), now: now)
        try fm.removeItem(atPath: live)                       // mirror-only, but recent mtime
        let report = mirror.reconcile(accounts: [acct(canonical)], canonicalDir: canonical.path,
                                      policy: RetentionPolicy(maxDays: 90, maxBytes: 0), now: now)
        XCTAssertTrue(fm.fileExists(atPath: live), "fresh entry should be restored")
        XCTAssertEqual(report.evicted.count, 0)
    }

    func testSizeCapEvictsOldestMirrorOnlyAndExemptsLiveShared() throws {
        let now = Date()
        // A: live-shared (nlink 2) — must never be counted/evicted for size
        let liveA = try writeTranscript(configDir: canonical, cwd: "-a", id: "aaaa", String(repeating: "x", count: 400))
        // B, C: mirror-only, C older than B
        let liveB = try writeTranscript(configDir: canonical, cwd: "-b", id: "bbbb", String(repeating: "y", count: 400))
        let liveC = try writeTranscript(configDir: canonical, cwd: "-c", id: "cccc", String(repeating: "z", count: 400))
        _ = mirror.reconcile(accounts: [acct(canonical)], canonicalDir: canonical.path, policy: policy(), now: now)
        let mpB = mirrorPath("-b", "bbbb", account: canonical), mpC = mirrorPath("-c", "cccc", account: canonical)
        try fm.removeItem(atPath: liveB); try fm.removeItem(atPath: liveC)
        try setMtime(mirrorPath("-a", "aaaa", account: canonical), daysAgo: 30, now: now)
        try setMtime(mpC, daysAgo: 10, now: now); try setMtime(mpB, daysAgo: 1, now: now)
        _ = liveA
        // cap = 500 bytes: total mirror-only = 800 → evict oldest (C) → 400 ≤ 500, keep B
        let report = mirror.reconcile(accounts: [acct(canonical)], canonicalDir: canonical.path,
                                      policy: RetentionPolicy(maxDays: 0, maxBytes: 500), now: now)
        XCTAssertFalse(fm.fileExists(atPath: mpC), "oldest mirror-only evicted")
        XCTAssertTrue(fm.fileExists(atPath: mpB), "newer mirror-only kept")
        XCTAssertTrue(fm.fileExists(atPath: mirrorPath("-a", "aaaa", account: canonical)), "live-shared exempt from size cap")
        XCTAssertTrue(report.evicted.contains(mpC))
    }

    func testSharedStoreSymlinkedCwdIsNotDoubleMirrored() throws {
        // Arrange: canonical has a live transcript under projects/-cwd/xxxx.jsonl
        let cwd = "-cwd", id = "xxxx"
        try writeTranscript(configDir: canonical, cwd: cwd, id: id, "data\n")

        // A second account dir whose projects/-cwd is a symlink back to canonical's
        let work = root.appendingPathComponent("work")
        try fm.createDirectory(at: work.appendingPathComponent("projects"), withIntermediateDirectories: true)
        let workCwdLink = work.appendingPathComponent("projects/\(cwd)").path
        let canonCwdDir = canonical.appendingPathComponent("projects/\(cwd)").path
        try fm.createSymbolicLink(atPath: workCwdLink, withDestinationPath: canonCwdDir)

        let canonAcct = acct(canonical)
        let workAcct  = acct(work)

        // Act: reconcile with both accounts
        let report = mirror.reconcile(accounts: [canonAcct, workAcct],
                                      canonicalDir: canonical.path, policy: policy())

        // Assert: mirror exists under canonical's key
        let canonMirror = mirrorPath(cwd, id, account: canonical)
        XCTAssertTrue(fm.fileExists(atPath: canonMirror), "canonical mirror must exist")

        // Assert: no mirror created under the work account (symlinked cwd skipped)
        let workMirror = mirrorPath(cwd, id, account: work)
        XCTAssertFalse(fm.fileExists(atPath: workMirror), "symlinked cwd must not produce a second mirror entry")

        // Exactly one link operation (from the canonical account's real entry)
        XCTAssertEqual(report.linked.count, 1)
    }

    func testPurgeRemovesMirrorAndLiveAndDoesNotResurrect() throws {
        let cwd = "-Users-x-proj", id = "ffff"
        let live = try writeTranscript(configDir: canonical, cwd: cwd, id: id, "secret\n")
        _ = mirror.reconcile(accounts: [acct(canonical)], canonicalDir: canonical.path, policy: policy())
        let mp = mirrorPath(cwd, id, account: canonical)
        try mirror.purge(sessionId: id, accounts: [acct(canonical)], canonicalDir: canonical.path)
        XCTAssertFalse(fm.fileExists(atPath: mp)); XCTAssertFalse(fm.fileExists(atPath: live))
        let report = mirror.reconcile(accounts: [acct(canonical)], canonicalDir: canonical.path, policy: policy())
        XCTAssertFalse(fm.fileExists(atPath: mp), "purge must not resurrect")
        XCTAssertEqual(report.restored.count, 0)
    }

    func testCrossVolumeFallsBackToCopyWithIssue() throws {
        let failingLink = FileOps(hardlink: { _, _ in throw NSError(domain: "EXDEV", code: 18) },
                                  copyFallback: { try FileManager.default.copyItem(atPath: $0, toPath: $1) })
        let m = TranscriptMirror(fileOps: failingLink)
        try writeTranscript(configDir: canonical, cwd: "-p", id: "gggg", "x\n")
        let report = m.reconcile(accounts: [acct(canonical)], canonicalDir: canonical.path, policy: policy())
        let mp = mirrorPath("-p", "gggg", account: canonical)
        XCTAssertTrue(fm.fileExists(atPath: mp), "copy fallback should still place a mirror")
        XCTAssertTrue(report.issues.contains { $0.contains("cross-volume") })
    }

    /// The production failure: a workspace mirrored under an account's key WHILE the
    /// account still had a real `projects/<cwd>`, then shared — Grove moved the dir
    /// into canonical and left a symlink. Step 1 now skips the symlink, so the old
    /// mirror looks orphaned and every reconcile tried to "restore" it onto a path
    /// where the very same file already is: `couldn't be linked to …`, forever.
    func testLeftoverMirrorUnderASharedCwdIsDroppedNotRestored() throws {
        let cwd = "-shared-later", id = "zzzz"
        let work = root.appendingPathComponent("work")
        let liveW = try writeTranscript(configDir: work, cwd: cwd, id: id, "data\n")
        // Mirrored while the dir was real.
        var report = mirror.reconcile(accounts: [acct(canonical), acct(work)], canonicalDir: canonical.path, policy: policy())
        let workMirror = mirrorPath(cwd, id, account: work)
        XCTAssertTrue(fm.fileExists(atPath: workMirror))
        // Then shared: the dir moves into canonical, a symlink stays behind.
        let canonCwd = canonical.appendingPathComponent("projects/\(cwd)").path
        try fm.createDirectory(atPath: canonical.appendingPathComponent("projects").path, withIntermediateDirectories: true)
        try fm.moveItem(atPath: work.appendingPathComponent("projects/\(cwd)").path, toPath: canonCwd)
        try fm.createSymbolicLink(atPath: work.appendingPathComponent("projects/\(cwd)").path, withDestinationPath: canonCwd)

        report = mirror.reconcile(accounts: [acct(canonical), acct(work)], canonicalDir: canonical.path, policy: policy())
        XCTAssertTrue(report.issues.isEmpty, "no restore attempted onto a file that is already there: \(report.issues)")
        XCTAssertTrue(fm.fileExists(atPath: liveW), "still reachable through the symlink")
        XCTAssertFalse(fm.fileExists(atPath: workMirror), "the leftover duplicate link is dropped")
        XCTAssertTrue(fm.fileExists(atPath: mirrorPath(cwd, id, account: canonical)), "canonical's own mirror holds the safety net")
        XCTAssertEqual(report.evicted, [workMirror])
        // And it stays quiet from now on.
        report = mirror.reconcile(accounts: [acct(canonical), acct(work)], canonicalDir: canonical.path, policy: policy())
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertTrue(report.evicted.isEmpty)
    }

    func testMultiAccountRestoreTargetsRightConfigDir() throws {
        let work = root.appendingPathComponent("acc-work")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let liveW = try writeTranscript(configDir: work, cwd: "-shared", id: "hhhh", "work\n")
        _ = mirror.reconcile(accounts: [acct(canonical), acct(work)], canonicalDir: canonical.path, policy: policy())
        try fm.removeItem(atPath: liveW)
        _ = mirror.reconcile(accounts: [acct(canonical), acct(work)], canonicalDir: canonical.path, policy: policy())
        XCTAssertTrue(fm.fileExists(atPath: liveW), "restored to the WORK account's projects, not canonical")
    }

    // test-local stat helper
    private func inode(_ path: String) -> Int? {
        (try? fm.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int
    }
}
