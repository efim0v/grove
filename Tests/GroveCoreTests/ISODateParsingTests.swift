import XCTest
@testable import GroveCore

/// `gitISODate` is on the hot path of usage analytics: a cold scan of the transcript
/// tree parses 200k+ timestamps through it. The old implementation went straight to
/// `ISO8601DateFormatter`, which is ~50× slower than integer parsing and pegged
/// `refreshUsage` for tens of seconds (the Daily-Usage stall). These tests pin the
/// parse results AND a cold-parse time budget so the fast path can't regress.
final class ISODateParsingTests: XCTestCase {

    // MARK: - Correctness (must match the formatters exactly for the common shapes)

    func testParsesTranscriptFractionalZulu() {
        // The dominant transcript shape: millis + Z.
        let s = "2026-06-19T12:22:15.475Z"
        let got = gitISODate(s)
        XCTAssertNotNil(got)
        XCTAssertEqual(got!.timeIntervalSince1970,
                       isoDateWithFractional.date(from: s)!.timeIntervalSince1970,
                       accuracy: 1e-6)
    }

    func testParsesGitOffsetFormExactly() {
        // git `%cI`: offset with a colon. 17:21:40+07:00 == 10:21:40Z (integer epoch).
        XCTAssertEqual(gitISODate("2026-06-16T17:21:40+07:00"),
                       isoDatePlain.date(from: "2026-06-16T10:21:40Z"))
    }

    func testParsesHalfHourOffsetExactly() {
        // A 30-minute offset must be honored. 13:00:00+05:30 == 07:30:00Z.
        XCTAssertEqual(gitISODate("2026-06-16T13:00:00+05:30"),
                       isoDatePlain.date(from: "2026-06-16T07:30:00Z"))
    }

    func testParsesPlainZuluAndZeroFractionExactly() {
        XCTAssertEqual(gitISODate("2026-06-10T09:58:11Z"),
                       isoDatePlain.date(from: "2026-06-10T09:58:11Z"))
        XCTAssertEqual(gitISODate("2026-06-10T09:58:11.000Z"),
                       isoDateWithFractional.date(from: "2026-06-10T09:58:11.000Z"))
    }

    func testRoundTripsKnownEpochs() {
        // Epoch anchors used elsewhere (UsageReaderTests) must round-trip exactly.
        XCTAssertEqual(gitISODate("2025-06-15T13:00:00Z"),
                       isoDatePlain.date(from: "2025-06-15T13:00:00Z"))
        // 1970 boundary via the civil-days math.
        XCTAssertEqual(gitISODate("1970-01-01T00:00:00Z"),
                       Date(timeIntervalSince1970: 0))
        // A leap day (civil-days correctness).
        XCTAssertEqual(gitISODate("2024-02-29T00:00:00Z"),
                       isoDatePlain.date(from: "2024-02-29T00:00:00Z"))
    }

    func testRejectsEmptyAndGarbage() {
        XCTAssertNil(gitISODate(""))
        XCTAssertNil(gitISODate("   "))
        XCTAssertNil(gitISODate("not-a-date"))
        XCTAssertNil(gitISODate("2026-13-40T99:99:99Z"))   // out-of-range fields
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(gitISODate("  2026-06-10T09:58:11Z\n"),
                       isoDatePlain.date(from: "2026-06-10T09:58:11Z"))
    }

    // MARK: - Performance budget (RED on the ISO8601DateFormatter hot path)

    func testParsesLargeBatchWithinBudget() {
        // Representative mix of the shapes a real transcript/git scan produces.
        let samples = [
            "2026-06-19T12:22:15.475Z",
            "2026-06-16T17:21:40+07:00",
            "2026-06-10T09:58:11Z",
            "2025-06-15T13:00:00.123Z",
            "2024-02-29T23:59:59.000Z",
        ]
        // Budget is generous so a DEBUG (-Onone) test build passes with ~4× margin
        // (fast path ≈ 250ms here, ≈ 30ms in release), while still catching a
        // regression to ISO8601DateFormatter — that path is ~91µs/call, i.e. ≈ 9s for
        // this batch, an order of magnitude over budget.
        let n = 100_000
        var sink = 0.0
        let start = Date()
        for i in 0..<n {
            if let d = gitISODate(samples[i % samples.count]) { sink += d.timeIntervalSince1970 }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(sink, 0)   // guard against dead-code elimination
        XCTAssertLessThan(elapsed, 1.0,
            "gitISODate too slow: \(Int(elapsed * 1000))ms for \(n) parses — the slow ISO8601DateFormatter path is back")
    }
}
