import Foundation

/// What `api/oauth/profile` says about the organisation behind a token. Only the
/// billing facts Brow shows: the endpoint carries no renewal date, so the best a
/// client can do is anchor a monthly cycle on `subscriptionCreatedAt`.
public struct OAuthProfile: Sendable, Equatable {
    public let organizationUuid: String?
    public let organizationType: String?
    public let billingType: String?
    public let subscriptionStatus: String?
    public let subscriptionCreatedAt: Date?
    public let rateLimitTier: String?

    public init(organizationUuid: String?, organizationType: String?, billingType: String?,
                subscriptionStatus: String?, subscriptionCreatedAt: Date?, rateLimitTier: String?) {
        self.organizationUuid = organizationUuid
        self.organizationType = organizationType
        self.billingType = billingType
        self.subscriptionStatus = subscriptionStatus
        self.subscriptionCreatedAt = subscriptionCreatedAt
        self.rateLimitTier = rateLimitTier
    }
}

/// One GET of `api/oauth/profile` with the account's own bearer. No cache and no
/// pacing of its own: the caller asks about once a day per account, and the endpoint
/// is not the rate-limited usage one.
public actor OAuthProfileClient {
    private let fetcher: UsageFetching
    private let credentials: CredentialsReading
    private let userAgent: String?

    public init(fetcher: UsageFetching, userAgent: String?, credentials: CredentialsReading = KeychainCredentialsReader()) {
        self.fetcher = fetcher
        self.userAgent = userAgent
        self.credentials = credentials
    }

    public func profile(configDir: String) async throws -> OAuthProfile {
        guard let token = credentials.accessToken(configDir: configDir) else { throw OAuthUsageError.noCredentials }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        let (data, status) = try await fetcher.fetch(request)
        if status == 401 || status == 403 { credentials.invalidate(configDir: configDir) }
        guard status == 429 ? false : (200..<300).contains(status) else {
            throw status == 429 ? OAuthUsageError.tooManyRequests : OAuthUsageError.http(status)
        }
        return try Self.parse(data)
    }

    public static func parse(_ data: Data) throws -> OAuthProfile {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthUsageError.malformed
        }
        let org = json["organization"] as? [String: Any] ?? [:]
        return OAuthProfile(organizationUuid: org["uuid"] as? String,
                            organizationType: org["organization_type"] as? String,
                            billingType: org["billing_type"] as? String,
                            subscriptionStatus: org["subscription_status"] as? String,
                            subscriptionCreatedAt: (org["subscription_created_at"] as? String).flatMap(Self.date),
                            rateLimitTier: org["rate_limit_tier"] as? String)
    }

    /// `2026-09-10T14:31:29.191836Z` — six fractional digits, which the plain
    /// internet-date-time formatter refuses; try with them, then without.
    static func date(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
