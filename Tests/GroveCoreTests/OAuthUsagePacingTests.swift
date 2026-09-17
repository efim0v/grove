import XCTest
@testable import GroveCore

/// The endpoint's real rate limit, measured 2026-09-17: a token bucket per access
/// token, refilled at about one request per 100 s, a burst of five after a rest,
/// `retry-after: 0` on every 429, and 429s that do not extend the penalty. The client
/// paces to that so a background poll never earns a 429 and the refresh button keeps
/// a burst budget of its own.
final class OAuthUsagePacingTests: XCTestCase {
    private final class Fetcher: UsageFetching, @unchecked Sendable {
        var status = 200
        var calls = 0
        func fetch(_ request: URLRequest) async throws -> (Data, Int) {
            calls += 1
            let body = #"{"five_hour":{"utilization":8,"resets_at":"2026-09-17T20:00:00Z"}}"#
            return (Data(body.utf8), status)
        }
    }
    private struct Creds: CredentialsReading {
        func token(configDir: String) -> ClaudeToken? { ClaudeToken(value: "t", expiresAt: nil) }
    }

    private let t0 = Date(timeIntervalSince1970: 1_758_000_000)

    private func client(_ fetcher: Fetcher, cache: TimeInterval = 30) -> OAuthUsageClient {
        OAuthUsageClient(fetcher: fetcher, userAgent: nil, cacheSeconds: cache, backoffCap: 300,
                         minInterval: 100, burstCapacity: 5, credentials: Creds())
    }

    func testBackgroundPollInsideTheRefillPeriodIsServedFromTheCache() async throws {
        let f = Fetcher()
        let c = client(f)
        _ = try await c.usage(configDir: "d", now: t0)
        XCTAssertEqual(f.calls, 1)
        // 30 s cache expired, but the endpoint's window has not re-opened: cache, no request.
        let early = try await c.usage(configDir: "d", now: t0.addingTimeInterval(61))
        XCTAssertEqual(f.calls, 1, "a poll inside the 100 s refill period must not hit the endpoint")
        XCTAssertEqual(early.fetchedAt, t0, "the cached reading keeps its real fetch instant")
        _ = try await c.usage(configDir: "d", now: t0.addingTimeInterval(101))
        XCTAssertEqual(f.calls, 2, "once the window re-opens the poll goes out")
    }

    func testForceSpendsTheBurstBudgetThenWaits() async throws {
        let f = Fetcher()
        let c = client(f)
        for i in 0..<5 {
            _ = try await c.usage(configDir: "d", now: t0.addingTimeInterval(Double(i)), force: true)
        }
        XCTAssertEqual(f.calls, 5, "a rested account absorbs a burst of five")
        do {
            _ = try await c.usage(configDir: "d", now: t0.addingTimeInterval(5), force: true)
            XCTFail("the sixth forced request must wait")
        } catch {
            XCTAssertEqual(error as? OAuthUsageError, .backoff)
        }
        XCTAssertEqual(f.calls, 5)
        let next = await c.nextAllowedAt(configDir: "d", force: true, now: t0.addingTimeInterval(5))
        // Five spent between t0 and t0+4 while the bucket kept refilling at 1/100 s, so
        // ~0.05 of a token had accrued by t0+5 and the next whole one lands at ~t0+100.
        XCTAssertEqual(next.timeIntervalSince1970, t0.addingTimeInterval(100).timeIntervalSince1970, accuracy: 1)
        _ = try await c.usage(configDir: "d", now: t0.addingTimeInterval(105), force: true)
        XCTAssertEqual(f.calls, 6, "the refilled token is spent")
    }

    func testNextAllowedAtForABackgroundPollIsTheRefillPeriodAfterTheLastSuccess() async throws {
        let f = Fetcher()
        let c = client(f)
        _ = try await c.usage(configDir: "d", now: t0)
        let next = await c.nextAllowedAt(configDir: "d", force: false, now: t0.addingTimeInterval(10))
        XCTAssertEqual(next, t0.addingTimeInterval(100))
        let forced = await c.nextAllowedAt(configDir: "d", force: true, now: t0.addingTimeInterval(10))
        XCTAssertEqual(forced, t0.addingTimeInterval(10), "with budget left a forced refresh goes out now")
    }

    func testA429AfterASuccessWaitsForTheRefillPeriodNotAnHour() async throws {
        let f = Fetcher()
        let c = client(f)
        _ = try await c.usage(configDir: "d", now: t0)
        f.status = 429
        do {
            _ = try await c.usage(configDir: "d", now: t0.addingTimeInterval(20), force: true)
            XCTFail("429 must throw")
        } catch {
            XCTAssertEqual(error as? OAuthUsageError, .tooManyRequests)
        }
        let next = await c.nextAllowedAt(configDir: "d", force: true, now: t0.addingTimeInterval(21))
        XCTAssertEqual(next, t0.addingTimeInterval(100), "the next token lands one refill period after the last 200")
        f.status = 200
        do {
            _ = try await c.usage(configDir: "d", now: t0.addingTimeInterval(99), force: true)
            XCTFail("still inside the window")
        } catch {
            XCTAssertEqual(error as? OAuthUsageError, .backoff)
        }
        _ = try await c.usage(configDir: "d", now: t0.addingTimeInterval(100), force: true)
        XCTAssertEqual(f.calls, 3)
    }

    func testTwoAccountsPaceIndependently() async throws {
        let f = Fetcher()
        let c = client(f)
        _ = try await c.usage(configDir: "a", now: t0)
        _ = try await c.usage(configDir: "b", now: t0.addingTimeInterval(2))
        XCTAssertEqual(f.calls, 2, "the limit is per token: the second account is not held by the first")
    }
}
