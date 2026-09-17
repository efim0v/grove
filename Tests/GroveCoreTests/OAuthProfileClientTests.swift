import XCTest
@testable import GroveCore

final class OAuthProfileClientTests: XCTestCase {
    private final class Fetcher: UsageFetching, @unchecked Sendable {
        var status = 200
        var body = ""
        var calls = 0
        func fetch(_ request: URLRequest) async throws -> (Data, Int) {
            calls += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/profile")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
            return (Data(body.utf8), status)
        }
    }
    private struct Creds: CredentialsReading {
        func token(configDir: String) -> ClaudeToken? { ClaudeToken(value: "t", expiresAt: nil) }
    }

    /// The shape the endpoint really returns (2026-09-18), trimmed to the organisation.
    private let sample = """
    {"account":{"uuid":"06d4","email":"x@example.com","has_claude_max":true},
     "organization":{"uuid":"a9c8","name":"x's Organization","organization_type":"claude_max",
       "billing_type":"stripe_subscription","rate_limit_tier":"default_claude_max_20x",
       "subscription_status":"active","subscription_created_at":"2026-09-10T14:31:29.191836Z"}}
    """

    func testParsesTheBillingFactsIncludingAFractionalSecondTimestamp() throws {
        let profile = try OAuthProfileClient.parse(Data(sample.utf8))
        XCTAssertEqual(profile.organizationUuid, "a9c8")
        XCTAssertEqual(profile.billingType, "stripe_subscription")
        XCTAssertEqual(profile.subscriptionStatus, "active")
        XCTAssertEqual(profile.rateLimitTier, "default_claude_max_20x")
        XCTAssertEqual(profile.subscriptionCreatedAt?.timeIntervalSince1970 ?? 0, 1_789_050_689.191836, accuracy: 0.001)
    }

    func testFetchesWithTheBearerAndMapsStatuses() async throws {
        let f = Fetcher()
        f.body = sample
        let c = OAuthProfileClient(fetcher: f, userAgent: nil, credentials: Creds())
        let profile = try await c.profile(configDir: "d")
        XCTAssertEqual(profile.organizationType, "claude_max")
        f.status = 429
        do { _ = try await c.profile(configDir: "d"); XCTFail("429 must throw") }
        catch { XCTAssertEqual(error as? OAuthUsageError, .tooManyRequests) }
        f.status = 500
        do { _ = try await c.profile(configDir: "d"); XCTFail("500 must throw") }
        catch { XCTAssertEqual(error as? OAuthUsageError, .http(500)) }
    }
}
