import Foundation
import XCTest
@testable import GroveCore

final class CodeStatsStoreTests: XCTestCase {

    private func point(_ date: Date, lines: Int, code: Int = 0, comment: Int = 0,
                       blank: Int = 0, files: Int = 1) -> CodeStatsPoint {
        CodeStatsPoint(date: date, totalLines: lines, code: code,
                       comment: comment, blank: blank, totalFiles: files)
    }

    private let base = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Round-trip

    func testAppendAndLoadRoundTrip() throws {
        let dir = try Fixture.tempDir("codestats-store")
        let store = CodeStatsStore(dir: dir)
        let id = UUID()

        let p = point(base, lines: 10, code: 8, comment: 1, blank: 1, files: 3)
        try store.append(projectID: id, point: p)

        let loaded = store.load(projectID: id)
        XCTAssertEqual(loaded.points.count, 1)
        XCTAssertEqual(loaded.points.first, p)
    }

    func testPerDayAddedRemovedSurviveRoundTrip() throws {
        let dir = try Fixture.tempDir("codestats-perday")
        let store = CodeStatsStore(dir: dir)
        let id = UUID()
        let p = CodeStatsPoint(date: base, totalLines: 10, code: 8, comment: 1, blank: 1,
                               totalFiles: 3, dayAdded: 42, dayRemoved: 7)
        try store.append(projectID: id, point: p)
        let loaded = store.load(projectID: id)
        XCTAssertEqual(loaded.points.first?.dayAdded, 42)
        XCTAssertEqual(loaded.points.first?.dayRemoved, 7)
        XCTAssertEqual(loaded.points.first, p)
    }

    func testLegacyJSONWithoutPerDayKeysDecodesToZero() throws {
        // A pre-existing history JSON written before dayAdded/dayRemoved existed must
        // still decode, defaulting the missing per-day fields to 0.
        let dir = try Fixture.tempDir("codestats-legacy")
        let id = UUID()
        let url = dir.appendingPathComponent("\(id.uuidString).json")
        let legacy = """
        {"points":[{"date":0,"totalLines":10,"code":8,"comment":1,"blank":1,"totalFiles":3}]}
        """
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let loaded = CodeStatsStore(dir: dir).load(projectID: id)
        XCTAssertEqual(loaded.points.count, 1)
        XCTAssertEqual(loaded.points.first?.totalLines, 10)
        XCTAssertEqual(loaded.points.first?.dayAdded, 0)
        XCTAssertEqual(loaded.points.first?.dayRemoved, 0)
    }

    func testMissingFileLoadsEmptyHistory() throws {
        let dir = try Fixture.tempDir("codestats-missing")
        let store = CodeStatsStore(dir: dir)
        XCTAssertEqual(store.load(projectID: UUID()), CodeStatsHistory())
    }

    func testDeleteRemovesHistoryFile() throws {
        let dir = try Fixture.tempDir("codestats-delete")
        let store = CodeStatsStore(dir: dir)
        let id = UUID()
        try store.append(projectID: id, point: point(base, lines: 10))
        XCTAssertEqual(store.load(projectID: id).points.count, 1)

        store.delete(projectID: id)
        XCTAssertEqual(store.load(projectID: id), CodeStatsHistory())   // back to empty
        store.delete(projectID: id)                                    // deleting again is a no-op
    }

    func testCorruptFileRecoversToEmptyHistory() throws {
        let dir = try Fixture.tempDir("codestats-corrupt")
        let store = CodeStatsStore(dir: dir)
        let id = UUID()
        let url = dir.appendingPathComponent("\(id.uuidString).json")
        try "{ not valid json".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(store.load(projectID: id), CodeStatsHistory(),
                       "corrupt file must degrade to an empty history, never crash")

        // A subsequent append rewrites the file cleanly.
        let p = point(base, lines: 5)
        try store.append(projectID: id, point: p)
        XCTAssertEqual(store.load(projectID: id).points, [p])
    }

    func testPerProjectIsolation() throws {
        let dir = try Fixture.tempDir("codestats-isolation")
        let store = CodeStatsStore(dir: dir)
        let a = UUID(), b = UUID()

        try store.append(projectID: a, point: point(base, lines: 1, files: 1))
        try store.append(projectID: b, point: point(base, lines: 99, files: 9))

        XCTAssertEqual(store.load(projectID: a).points.map(\.totalLines), [1])
        XCTAssertEqual(store.load(projectID: b).points.map(\.totalLines), [99])

        // Each project writes its own <uuid>.json file.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("\(a.uuidString).json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("\(b.uuidString).json").path))
    }

    func testAppendCreatesParentDir() throws {
        let dir = try Fixture.tempDir("codestats-mkdir").appendingPathComponent("nested/deeper")
        let store = CodeStatsStore(dir: dir)
        let id = UUID()
        try store.append(projectID: id, point: point(base, lines: 3))
        XCTAssertEqual(store.load(projectID: id).points.count, 1)
        // tmp + rename must not leave stray temp files behind.
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(entries, ["\(id.uuidString).json"])
    }

    // MARK: - coalesce

    func testCoalesceAppendsToEmptyHistory() {
        let p = point(base, lines: 10)
        let out = CodeStatsStore.coalesce(history: CodeStatsHistory(), newPoint: p, minInterval: 3600)
        XCTAssertEqual(out.points, [p])
    }

    func testCoalesceAppendsWhenTotalsChange() {
        let first = point(base, lines: 10, files: 2)
        let second = point(base.addingTimeInterval(5), lines: 11, files: 2)  // lines changed
        var history = CodeStatsHistory(points: [first])
        history = CodeStatsStore.coalesce(history: history, newPoint: second, minInterval: 3600)
        XCTAssertEqual(history.points, [first, second])
    }

    func testCoalesceReplacesTrailingPointWhenUnchangedWithinInterval() {
        let first = point(base, lines: 10, code: 8, comment: 1, blank: 1, files: 2)
        // Same counts, 5s later, well within the 1h interval -> replace, don't append.
        let second = point(base.addingTimeInterval(5), lines: 10, code: 8, comment: 1, blank: 1, files: 2)
        var history = CodeStatsHistory(points: [first])
        history = CodeStatsStore.coalesce(history: history, newPoint: second, minInterval: 3600)
        XCTAssertEqual(history.points.count, 1)
        XCTAssertEqual(history.points.first?.date, second.date,
                       "the replacement keeps the latest timestamp")
    }

    func testCoalesceAppendsWhenIntervalElapsedEvenIfUnchanged() {
        let first = point(base, lines: 10, files: 2)
        // Identical counts but >= minInterval later -> append (a heartbeat sample).
        let second = point(base.addingTimeInterval(3600), lines: 10, files: 2)
        var history = CodeStatsHistory(points: [first])
        history = CodeStatsStore.coalesce(history: history, newPoint: second, minInterval: 3600)
        XCTAssertEqual(history.points, [first, second])
    }

    func testAppendCoalescesAcrossLoads() throws {
        let dir = try Fixture.tempDir("codestats-coalesce-persist")
        let store = CodeStatsStore(dir: dir)
        let id = UUID()

        try store.append(projectID: id, point: point(base, lines: 10, files: 2), minInterval: 3600)
        // Same totals 5s later within the interval -> trailing point replaced, not grown.
        try store.append(projectID: id, point: point(base.addingTimeInterval(5), lines: 10, files: 2),
                         minInterval: 3600)
        XCTAssertEqual(store.load(projectID: id).points.count, 1)

        // A changed total appends a new point.
        try store.append(projectID: id, point: point(base.addingTimeInterval(10), lines: 12, files: 2),
                         minInterval: 3600)
        XCTAssertEqual(store.load(projectID: id).points.map(\.totalLines), [10, 12])
    }
}
