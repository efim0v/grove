import XCTest
@testable import GroveCore

final class HotJSONFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotjson-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testCreatesAbsentFileWithRequestedMode() throws {
        let file = root.appendingPathComponent("sub/.claude.json")
        let outcome = try HotJSONFile.update(path: file.path, mode: 0o600) { _ in ["a": 1] }
        XCTAssertEqual(outcome, .written)
        XCTAssertEqual(try read(file)["a"] as? Int, 1)
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".lock"))
    }

    /// The common hot-migration case: nothing to add → the running account's file
    /// is not touched at all (same inode, same mtime).
    func testNoOpMergeLeavesTheFileUntouched() throws {
        let file = root.appendingPathComponent("settings.json")
        try Data(#"{"theme":"dark"}"#.utf8).write(to: file)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)

        let outcome = try HotJSONFile.update(path: file.path) { $0 }

        XCTAssertEqual(outcome, .unchanged)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(before[.systemFileNumber] as? Int, after[.systemFileNumber] as? Int)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    }

    func testPreservesExistingModeWhenNoneRequested() throws {
        let file = root.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        try HotJSONFile.update(path: file.path) { _ in ["k": "v"] }
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o640)
    }

    /// An unparseable config must never be replaced by "just our keys".
    func testUnparseableFileIsNeverOverwritten() throws {
        let file = root.appendingPathComponent(".claude.json")
        let garbage = Data(#"{"oauthAccount": {"emailAddr"#.utf8)
        try garbage.write(to: file)

        XCTAssertThrowsError(try HotJSONFile.update(path: file.path) { _ in ["projects": [:]] }) {
            XCTAssertEqual($0 as? HotJSONFile.Failure, .unparseable(file.path))
        }
        XCTAssertEqual(try Data(contentsOf: file), garbage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".lock"))
    }

    /// A writer that lands between our read and our swap is merged, not clobbered.
    func testConcurrentWriteDuringMergeIsNotLost() throws {
        let file = root.appendingPathComponent(".claude.json")
        try Data(#"{"numStartups":1}"#.utf8).write(to: file)

        var calls = 0
        let outcome = try HotJSONFile.update(path: file.path) { current in
            calls += 1
            if calls == 1 {
                // A running claude saves its config mid-merge (atomic replace → new inode).
                try? Data(#"{"numStartups":2,"liveKey":"kept"}"#.utf8).write(to: file, options: .atomic)
            }
            var merged = current
            merged["ours"] = true
            return merged
        }

        XCTAssertEqual(outcome, .written)
        XCTAssertEqual(calls, 2, "the merge must be redone on the fresh content")
        let result = try read(file)
        XCTAssertEqual(result["numStartups"] as? Int, 2)
        XCTAssertEqual(result["liveKey"] as? String, "kept")
        XCTAssertEqual(result["ours"] as? Bool, true)
    }

    /// Claude holds `<file>.lock` (a directory) while saving: we wait, then proceed.
    func testWaitsForAFreshLockThenProceeds() throws {
        let file = root.appendingPathComponent(".claude.json")
        try Data("{}".utf8).write(to: file)
        let lock = file.path + ".lock"
        try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { rmdir(lock) }

        let outcome = try HotJSONFile.update(path: file.path) { _ in ["a": 1] }
        XCTAssertEqual(outcome, .written)
    }

    func testHeldLockTimesOutWithoutWriting() throws {
        let file = root.appendingPathComponent(".claude.json")
        try Data("{}".utf8).write(to: file)
        let lock = file.path + ".lock"
        try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false)
        defer { rmdir(lock) }

        XCTAssertThrowsError(try HotJSONFile.update(path: file.path, lockWait: 0.2) { _ in ["a": 1] }) {
            XCTAssertEqual($0 as? HotJSONFile.Failure, .lockTimeout(file.path))
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("{}".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock), "someone else's lock must not be removed")
    }

    /// A lock left behind by a crashed holder (mtime older than the stale age) is reclaimed.
    func testStaleLockIsReclaimed() throws {
        let file = root.appendingPathComponent(".claude.json")
        try Data("{}".utf8).write(to: file)
        let lock = file.path + ".lock"
        try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: lock)

        let outcome = try HotJSONFile.update(path: file.path, lockWait: 0.2) { _ in ["a": 1] }
        XCTAssertEqual(outcome, .written)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock))
    }

    /// A symlinked config is written THROUGH, not replaced by a regular file.
    func testWritesThroughASymlink() throws {
        let real = root.appendingPathComponent("real.json")
        let link = root.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try HotJSONFile.update(path: link.path) { _ in ["a": 1] }

        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink)
        XCTAssertEqual(try read(real)["a"] as? Int, 1)
    }
}
