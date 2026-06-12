import XCTest
@testable import GroveCore

final class UsageReaderTests: XCTestCase {
    private let fm = FileManager.default
    private var configDir: URL!
    private let reader = UsageReader()

    override func setUpWithError() throws {
        configDir = try Fixture.tempDir("usage-reader")
    }

    private func writeSnapshot(_ rel: String, _ json: String) throws {
        let url = configDir.appendingPathComponent("grove/usage").appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    func testReadsCaptureSnapshotsWithRateLimitsWhenPresent() throws {
        try writeSnapshot("sess-1.json", #"""
        {"capturedAt":"2025-06-15T10:00:00Z","raw":{
          "session_id":"sess-1","model":{"display_name":"Opus","id":"claude-opus-4-6"},
          "workspace":{"current_dir":"/ws/x"},
          "context_window":{"used_percentage":42.5,"total_input_tokens":12345},
          "cost":{"total_cost_usd":1.25},"effort":{"level":"high"},
          "rate_limits":{
            "five_hour":{"used_percentage":30,"resets_at":"2025-06-15T13:00:00Z"},
            "seven_day":{"used_percentage":12,"resets_at":"2025-06-20T00:00:00Z"}}}}
        """#)
        let snaps = reader.read(configDir: configDir.path, accountName: "default")
        let s = try XCTUnwrap(snaps.first)
        XCTAssertEqual(s.sessionId, "sess-1")
        XCTAssertEqual(s.accountName, "default")
        XCTAssertEqual(s.cwd, "/ws/x")
        XCTAssertEqual(s.modelId, "claude-opus-4-6")
        XCTAssertEqual(s.contextUsedPercentage, 42.5)
        XCTAssertEqual(s.totalCostUSD, 1.25)
        XCTAssertEqual(s.effort, "high")
        XCTAssertEqual(s.fiveHour?.usedPercentage, 30)
        XCTAssertEqual(s.fiveHour?.resetsAt, "2025-06-15T13:00:00Z")
        XCTAssertEqual(s.sevenDay?.usedPercentage, 12)
    }

    func testRateLimitsAbsentIsHandledAsNil() throws {
        try writeSnapshot("sess-2.json", #"""
        {"capturedAt":"2025-06-15T10:00:00Z","raw":{
          "session_id":"sess-2","model":{"id":"claude-sonnet-4-6"},
          "workspace":{"current_dir":"/ws/y"}}}
        """#)
        let s = try XCTUnwrap(reader.read(configDir: configDir.path, accountName: "work").first)
        XCTAssertNil(s.fiveHour)        // rate_limits absent -> nil, not a crash
        XCTAssertNil(s.sevenDay)
    }

    func testMalformedSnapshotIsSkippedNotFatal() throws {
        try writeSnapshot("good.json", #"{"capturedAt":"2025-06-15T10:00:00Z","raw":{"session_id":"g","workspace":{"current_dir":"/ws"}}}"#)
        try writeSnapshot("bad.json", "{ not json")
        let snaps = reader.read(configDir: configDir.path, accountName: "a")
        XCTAssertEqual(snaps.map(\.sessionId), ["g"], "the corrupt file is skipped")
    }

    func testMissingUsageDirYieldsEmpty() {
        XCTAssertEqual(reader.read(configDir: configDir.path, accountName: "a").count, 0)
    }
}
