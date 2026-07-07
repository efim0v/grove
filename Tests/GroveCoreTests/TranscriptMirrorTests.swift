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

    // test-local stat helper
    private func inode(_ path: String) -> Int? {
        (try? fm.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int
    }
}
