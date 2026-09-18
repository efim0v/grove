import XCTest
@testable import GroveAppKit

/// The panel footer states the date AND time the limits were obtained.
final class UsageAsOfFormattingTests: XCTestCase {
    private let locale = Locale(identifier: "en_GB")     // fixed: d MMM, 24h clock
    private let utc = TimeZone(identifier: "UTC")!

    func testFormatsDateAndTime() {
        // 2025-06-15T15:12:00Z
        let date = Date(timeIntervalSince1970: 1_750_000_320)
        let text = formatAsOf(date, locale: locale, timeZone: utc)
        XCTAssertTrue(text.contains("15 Jun"), "day and abbreviated month, got \(text)")
        XCTAssertTrue(text.contains("15:12"), "hour and minute, got \(text)")
    }

    func testNilReadsAsEmDash() {
        XCTAssertEqual(formatAsOf(nil, locale: locale, timeZone: utc), "—")
    }

    func testRendersInTheGivenTimeZone() {
        let date = Date(timeIntervalSince1970: 1_750_000_320)
        let berlin = TimeZone(identifier: "Europe/Berlin")!    // UTC+2 in June
        XCTAssertTrue(formatAsOf(date, locale: locale, timeZone: berlin).contains("17:12"))
    }
}
