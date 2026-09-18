import XCTest
@testable import GroveCore

/// The three-way answer a credentials read gives, and what the caching reader does
/// with a `.locked` one: remembers it for the floor, says so, and only a `grant`
/// goes back to the Keychain with the dialog allowed.
final class CredentialsAccessTests: XCTestCase {
    private final class Base: CredentialsReading, @unchecked Sendable {
        var answer: CredentialsAccess = .locked
        var reads = 0
        var grants = 0
        func access(configDir: String) -> CredentialsAccess { reads += 1; return answer }
        func grant(configDir: String) -> CredentialsAccess { grants += 1; return answer }
        func token(configDir: String) -> ClaudeToken? {
            if case .token(let t) = access(configDir: configDir) { return t }
            return nil
        }
    }
    private let t0 = Date(timeIntervalSince1970: 1_758_000_000)

    func testLockedIsRememberedForTheFloorAndReadsAsNoToken() {
        let base = Base()
        var now = t0
        let reader = CachingCredentialsReader(base: base, now: { now })
        XCTAssertEqual(reader.access(configDir: "d"), .locked)
        XCTAssertNil(reader.token(configDir: "d"))
        now = t0.addingTimeInterval(30)
        XCTAssertEqual(reader.access(configDir: "d"), .locked, "inside the floor the answer is the remembered one")
        XCTAssertEqual(base.reads, 1, "and the Keychain is not asked again")
        now = t0.addingTimeInterval(CachingCredentialsReader.nilReadFloor + 1)
        base.answer = .missing
        XCTAssertEqual(reader.access(configDir: "d"), .missing)
        XCTAssertEqual(base.reads, 2)
    }

    func testGrantAsksTheBaseWithTheDialogAndCachesWhatItGets() {
        let base = Base()
        let reader = CachingCredentialsReader(base: base, now: { [t0] in t0 })
        XCTAssertEqual(reader.access(configDir: "d"), .locked)
        let token = ClaudeToken(value: "t", expiresAt: t0.addingTimeInterval(3600))
        base.answer = .token(token)
        XCTAssertEqual(reader.grant(configDir: "d"), .token(token))
        XCTAssertEqual(base.grants, 1)
        XCTAssertEqual(reader.token(configDir: "d"), token, "served from the cache now")
        XCTAssertEqual(base.reads, 1)
    }

    func testDefaultsDeriveAccessFromTokenWithItsExpiry() {
        let expiry = Date(timeIntervalSince1970: 5)
        struct TokenOnly: CredentialsReading {
            let expiry: Date
            func token(configDir: String) -> ClaudeToken? { ClaudeToken(value: "x", expiresAt: expiry) }
        }
        XCTAssertEqual(TokenOnly(expiry: expiry).access(configDir: "d"), .token(ClaudeToken(value: "x", expiresAt: expiry)))
        XCTAssertEqual(TokenOnly(expiry: expiry).accessToken(configDir: "d"), "x")
        XCTAssertEqual(TokenOnly(expiry: expiry).grant(configDir: "d"), .token(ClaudeToken(value: "x", expiresAt: expiry)),
                       "a reader with no dialog grants what it reads")
    }
}
