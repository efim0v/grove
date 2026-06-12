import XCTest
@testable import GroveCore

final class SharedSessionStoreTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var canonicalDir: URL!     // stands in for ~/.claude (NEVER the real one)
    private var accountDir: URL!       // a linked account's CLAUDE_CONFIG_DIR
    private let store = SharedSessionStore()

    override func setUpWithError() throws {
        root = try Fixture.tempDir("shared-store")
        canonicalDir = root.appendingPathComponent("canonical")   // ~/.claude analogue
        accountDir = root.appendingPathComponent("acc-work")
        try fm.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: accountDir, withIntermediateDirectories: true)
    }

    // MARK: - helpers

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private func symlinkTarget(_ url: URL) throws -> String {
        try fm.destinationOfSymbolicLink(atPath: url.path)
    }

    /// Writes file `<dir>/<rel>` creating intermediate dirs.
    private func write(_ content: String, at dir: URL, _ rel: String) throws {
        let url = dir.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ dir: URL, _ rel: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8)
    }

    // MARK: - wholesaleDirs is the single source of truth

    func testWholesaleDirsAreExactlyTheThreeUuidStores() {
        XCTAssertEqual(SharedSessionStore.wholesaleDirs, ["file-history", "tasks", "session-env"])
    }

    // MARK: - knownNonSharedDirs is the single source of truth for verify's allowlist

    func testKnownNonSharedDirsCoverTheLocalAndBackupStores() {
        XCTAssertEqual(SharedSessionStore.knownNonSharedDirs,
                       ["projects", "sessions", "shell-snapshots", "todos", "statsig", "grove-backup"])
    }

    func testVerifyFlagsAnUnknownTopLevelStoreDir() throws {
        // A future Claude store we don't know about surfaces as a banner, not silence.
        try write("x", at: accountDir, "memory-vault/some/file.txt")
        // Link the wholesale dirs so only the unknown dir is flagged.
        _ = try store.ensureLinked(accountDir: accountDir.path, canonicalDir: canonicalDir.path)
        let issues = store.verify(accountDirs: [accountDir.path], canonicalDir: canonicalDir.path)
        XCTAssertTrue(issues.contains { $0.contains("memory-vault") && $0.lowercased().contains("unknown") },
                      "got: \(issues)")
    }

    // MARK: - fresh link creates symlinks pointing into canonical

    func testEnsureLinkedCreatesSymlinksForAllWholesaleDirsWhenAccountHasNone() throws {
        let log = try store.ensureLinked(accountDir: accountDir.path, canonicalDir: canonicalDir.path)

        for name in SharedSessionStore.wholesaleDirs {
            let link = accountDir.appendingPathComponent(name)
            XCTAssertTrue(isSymlink(link), "\(name) must be a symlink")
            XCTAssertEqual(try symlinkTarget(link),
                           canonicalDir.appendingPathComponent(name).path,
                           "\(name) must point into canonical")
            // The canonical real dir exists (created when absent).
            var isDir: ObjCBool = false
            XCTAssertTrue(fm.fileExists(atPath: canonicalDir.appendingPathComponent(name).path,
                                        isDirectory: &isDir) && isDir.boolValue)
        }
        XCTAssertFalse(log.isEmpty, "ensureLinked returns log lines")
    }

    // MARK: - migrate-merge moves UUID entries without clobber, with backup

    func testEnsureLinkedMigratesAccountEntriesIntoCanonicalThenSymlinks() throws {
        // Account has a real file-history dir with two UUID-named session dirs;
        // canonical already owns ONE of them with DIFFERENT content (collision).
        let u1 = "11111111-1111-4111-8111-111111111111"
        let u2 = "22222222-2222-4222-8222-222222222222"
        try write("ACCOUNT-u1", at: accountDir, "file-history/\(u1)/snap.txt")
        try write("ACCOUNT-u2", at: accountDir, "file-history/\(u2)/snap.txt")
        try write("CANON-u1",   at: canonicalDir, "file-history/\(u1)/snap.txt")  // collision on u1

        let log = try store.ensureLinked(accountDir: accountDir.path, canonicalDir: canonicalDir.path)

        // file-history is now a symlink into canonical.
        let link = accountDir.appendingPathComponent("file-history")
        XCTAssertTrue(isSymlink(link))
        XCTAssertEqual(try symlinkTarget(link),
                       canonicalDir.appendingPathComponent("file-history").path)

        // u2 (canonical lacked it) was MOVED into canonical.
        XCTAssertEqual(try read(canonicalDir, "file-history/\(u2)/snap.txt"), "ACCOUNT-u2")
        // u1 collision: canonical's copy is KEPT untouched.
        XCTAssertEqual(try read(canonicalDir, "file-history/\(u1)/snap.txt"), "CANON-u1")
        // The account's pre-link file-history (incl. the conflicting u1) was backed up.
        let backups = try fm.contentsOfDirectory(
            atPath: accountDir.appendingPathComponent("grove-backup").path)
        XCTAssertFalse(backups.isEmpty, "a backup label dir exists under grove-backup")
        // The conflicting u1 specifically survives in the backup (nothing clobbered).
        let backupHasU1 = try fm.subpathsOfDirectory(
            atPath: accountDir.appendingPathComponent("grove-backup").path)
            .contains { $0.hasSuffix("\(u1)/snap.txt") }
        XCTAssertTrue(backupHasU1, "the account's conflicting u1 is preserved in the backup")
        XCTAssertTrue(log.contains { $0.contains("file-history") })
    }

    // MARK: - idempotent re-link

    func testEnsureLinkedIsIdempotent() throws {
        _ = try store.ensureLinked(accountDir: accountDir.path, canonicalDir: canonicalDir.path)
        let backupsBefore = (try? fm.contentsOfDirectory(
            atPath: accountDir.appendingPathComponent("grove-backup").path)) ?? []

        // Second call: every dir is already a correct symlink → no-op, no new backup.
        let log = try store.ensureLinked(accountDir: accountDir.path, canonicalDir: canonicalDir.path)

        for name in SharedSessionStore.wholesaleDirs {
            XCTAssertTrue(isSymlink(accountDir.appendingPathComponent(name)))
        }
        let backupsAfter = (try? fm.contentsOfDirectory(
            atPath: accountDir.appendingPathComponent("grove-backup").path)) ?? []
        XCTAssertEqual(backupsAfter.count, backupsBefore.count,
                       "re-linking an already-linked account takes no new backup")
        XCTAssertTrue(log.allSatisfy { $0.lowercased().contains("already") },
                      "idempotent re-link reports already-linked, got: \(log)")
    }

    // MARK: - per-workspace projects symlink

    func testEnsureWorkspaceLinkedSymlinksTheCwdProjectsDir() throws {
        let mangled = ClaudeService.mangle("/Users/demo/Workspaces/feat-x")
        // Account already has a real projects/<mangled> with one transcript →
        // migrate-merge then symlink (UUID jsonl is collision-free).
        try write("transcript", at: accountDir, "projects/\(mangled)/sess.jsonl")

        let created = try store.ensureWorkspaceLinked(
            accountDir: accountDir.path, canonicalDir: canonicalDir.path, mangledCwd: mangled)

        XCTAssertTrue(created, "returns true when it established/changed the link")
        let link = accountDir.appendingPathComponent("projects/\(mangled)")
        XCTAssertTrue(isSymlink(link))
        XCTAssertEqual(try symlinkTarget(link),
                       canonicalDir.appendingPathComponent("projects/\(mangled)").path)
        XCTAssertEqual(try read(canonicalDir, "projects/\(mangled)/sess.jsonl"), "transcript")
    }

    func testEnsureWorkspaceLinkedIsIdempotent() throws {
        let mangled = ClaudeService.mangle("/Users/demo/Workspaces/feat-y")
        _ = try store.ensureWorkspaceLinked(
            accountDir: accountDir.path, canonicalDir: canonicalDir.path, mangledCwd: mangled)
        let created = try store.ensureWorkspaceLinked(
            accountDir: accountDir.path, canonicalDir: canonicalDir.path, mangledCwd: mangled)
        XCTAssertFalse(created, "already a correct symlink → no change")
    }

    /// Target-side migrate-merge: the TARGET account already owns a real
    /// projects/<mangled> dir holding an UNRELATED transcript while canonical (the
    /// owner's already-linked copy) holds the shared one. Linking the target must
    /// migrate-merge the target's unrelated transcript into canonical (collision-
    /// free — different sessionId → different filename) and replace target's dir
    /// with a symlink, so BOTH transcripts end up under canonical.
    func testEnsureWorkspaceLinkedMigratesTargetSideUnrelatedTranscriptIntoCanonical() throws {
        let mangled = ClaudeService.mangle("/Users/demo/Workspaces/feat-merge")
        // Canonical already owns the shared transcript (owner linked first).
        try write("OWNER", at: canonicalDir, "projects/\(mangled)/owner-id.jsonl")
        // The target account independently has its own UNRELATED transcript at the same cwd.
        try write("TARGET", at: accountDir, "projects/\(mangled)/other-id.jsonl")

        let created = try store.ensureWorkspaceLinked(
            accountDir: accountDir.path, canonicalDir: canonicalDir.path, mangledCwd: mangled)

        XCTAssertTrue(created, "target's real dir is migrate-merged then symlinked")
        // Target's dir is now a symlink into canonical.
        let link = accountDir.appendingPathComponent("projects/\(mangled)")
        XCTAssertTrue(isSymlink(link))
        XCTAssertEqual(try symlinkTarget(link),
                       canonicalDir.appendingPathComponent("projects/\(mangled)").path)
        // BOTH transcripts now live under canonical, collision-free.
        XCTAssertEqual(try read(canonicalDir, "projects/\(mangled)/owner-id.jsonl"), "OWNER")
        XCTAssertEqual(try read(canonicalDir, "projects/\(mangled)/other-id.jsonl"), "TARGET")
        // A backup of the target's pre-link projects/<mangled> dir exists.
        let backups = try fm.subpathsOfDirectory(
            atPath: accountDir.appendingPathComponent("grove-backup").path)
        XCTAssertTrue(backups.contains { $0.contains("workspace-") },
                      "the target's pre-link dir was backed up under grove-backup")
    }

    // MARK: - verify

    func testVerifyReturnsEmptyForAHealthyLinkedAccount() throws {
        _ = try store.ensureLinked(accountDir: accountDir.path, canonicalDir: canonicalDir.path)
        let issues = store.verify(accountDirs: [accountDir.path], canonicalDir: canonicalDir.path)
        XCTAssertEqual(issues, [])
    }

    func testVerifyFlagsABrokenSymlink() throws {
        // A file-history symlink that points nowhere (canonical target deleted).
        let link = accountDir.appendingPathComponent("file-history")
        try fm.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: canonicalDir.appendingPathComponent("file-history").path)
        // canonical/file-history was never created → dangling link.
        let issues = store.verify(accountDirs: [accountDir.path], canonicalDir: canonicalDir.path)
        XCTAssertTrue(issues.contains { $0.contains("file-history") && $0.lowercased().contains("broken") },
                      "got: \(issues)")
    }

    func testVerifyFlagsAWholesaleDirThatIsARealDirInsteadOfASymlink() throws {
        // The account is marked-for-sharing but tasks is still a real dir (never linked).
        try write("x", at: accountDir, "tasks/some/file.txt")
        // Make the OTHER two correct so only tasks is flagged.
        for name in ["file-history", "session-env"] {
            try fm.createDirectory(at: canonicalDir.appendingPathComponent(name),
                                   withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                atPath: accountDir.appendingPathComponent(name).path,
                withDestinationPath: canonicalDir.appendingPathComponent(name).path)
        }
        let issues = store.verify(accountDirs: [accountDir.path], canonicalDir: canonicalDir.path)
        XCTAssertTrue(issues.contains { $0.contains("tasks") }, "got: \(issues)")
        XCTAssertFalse(issues.contains { $0.contains("file-history") })
    }

    // MARK: - unlink restores real dirs

    func testUnlinkReplacesSymlinksWithRealDirsCopiedBackFromCanonical() throws {
        // Link, write a NEW entry through the link (lands in canonical), then unlink.
        _ = try store.ensureLinked(accountDir: accountDir.path, canonicalDir: canonicalDir.path)
        let u = "33333333-3333-4333-8333-333333333333"
        try write("through-the-link", at: canonicalDir, "file-history/\(u)/snap.txt")

        try store.unlink(accountDir: accountDir.path, canonicalDir: canonicalDir.path)

        for name in SharedSessionStore.wholesaleDirs {
            let dir = accountDir.appendingPathComponent(name)
            XCTAssertFalse(isSymlink(dir), "\(name) is a real dir again after unlink")
            var isDir: ObjCBool = false
            XCTAssertTrue(fm.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
        }
        // The shared content is copied back so the account keeps its history.
        XCTAssertEqual(try read(accountDir, "file-history/\(u)/snap.txt"), "through-the-link")
        // Canonical is left intact (other accounts still share it).
        XCTAssertEqual(try read(canonicalDir, "file-history/\(u)/snap.txt"), "through-the-link")
    }
}
