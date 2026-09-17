import Foundation

/// Network seam: returns (body, httpStatus). The production impl wraps
/// URLSession; tests inject canned responses so NOTHING hits the real endpoint.
public protocol UsageFetching: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, Int)
}

/// Default production fetcher over URLSession (the ONLY place a real request is made).
public struct URLSessionUsageFetcher: UsageFetching {
    public init() {}
    public func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}

public struct OAuthWindow: Sendable, Equatable {
    public let utilization: Double
    public let resetsAt: String?
    public init(utilization: Double, resetsAt: String?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

/// A model-scoped weekly window from the `limits[]` `weekly_scoped` entry.
public struct OAuthScopedWindow: Sendable, Equatable {
    public let utilization: Double
    public let resetsAt: String?
    public let modelDisplayName: String?
    public init(utilization: Double, resetsAt: String?, modelDisplayName: String?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.modelDisplayName = modelDisplayName
    }
}

public struct OAuthUsage: Sendable, Equatable {
    public let fiveHour: OAuthWindow?
    public let sevenDay: OAuthWindow?
    public let sevenDaySonnet: OAuthWindow?
    public let sevenDayOpus: OAuthWindow?
    /// 7-day Fable-specific window. Parsed opportunistically from the OAuth response
    /// via the legacy per-model top-level keys (currently null in live payloads).
    public let sevenDayFable: OAuthWindow?
    /// Model-scoped weekly window derived from `limits[]` `kind:"weekly_scoped"`.
    /// This is the PRIMARY source for the per-model bar. Contains the model display
    /// name (e.g. "Fable", "Opus") from `scope.model.display_name`.
    public let weeklyScoped: OAuthScopedWindow?
    /// When this reading was REALLY fetched from the API. A cache hit carries the
    /// instant of the original request, not the moment it was served — the panel's
    /// "Updated …" line would otherwise claim three-minute-old numbers are current.
    /// nil means "unknown" (canned values in tests); callers substitute their own now.
    public let fetchedAt: Date?
    public init(fiveHour: OAuthWindow?, sevenDay: OAuthWindow?,
                sevenDaySonnet: OAuthWindow?, sevenDayOpus: OAuthWindow?,
                sevenDayFable: OAuthWindow? = nil,
                weeklyScoped: OAuthScopedWindow? = nil,
                fetchedAt: Date? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDaySonnet = sevenDaySonnet
        self.sevenDayOpus = sevenDayOpus
        self.sevenDayFable = sevenDayFable
        self.weeklyScoped = weeklyScoped
        self.fetchedAt = fetchedAt
    }

    /// A copy stamped with the instant it was fetched.
    func stamped(fetchedAt: Date) -> OAuthUsage {
        OAuthUsage(fiveHour: fiveHour, sevenDay: sevenDay, sevenDaySonnet: sevenDaySonnet,
                   sevenDayOpus: sevenDayOpus, sevenDayFable: sevenDayFable,
                   weeklyScoped: weeklyScoped, fetchedAt: fetchedAt)
    }
}

public enum OAuthUsageError: Error, Equatable {
    case noCredentials
    case tooManyRequests        // 429
    case backoff                // suppressed retry inside the backoff window
    case http(Int)
    case malformed
}

/// Opt-in (spec §C.4, off by default), fragile `api/oauth/usage` poll. Cache ≥3min,
/// exponential backoff on 429. The fetcher is injected; the bearer is read from
/// `<configDir>/.credentials.json`. `now` drives the cache/backoff clock (no Date()).
public actor OAuthUsageClient {
    private let fetcher: UsageFetching
    private let credentials: CredentialsReading
    /// `User-Agent` for every request, or nil to send none. Grove identifies as
    /// Claude Code, as it always has; Brow sends no `claude-code/…` header at all
    /// (spec, Risks: "Brow does not send a claude-code/… User-Agent") — a
    /// third-party app must not claim to be Anthropic's own client.
    private let userAgent: String?
    private let cacheSeconds: TimeInterval
    /// Longest 429 suppression. Grove polls slowly and keeps the hour; Brow polls
    /// every minute or two and passes 300 s so a burst never freezes its readout.
    private let backoffCap: TimeInterval

    private var cache: [String: (at: Date, value: OAuthUsage)] = [:]
    private var backoff: [String: (until: Date, attempts: Int)] = [:]

    /// Identifies as `claude-code/<appVersion>` — Grove's long-standing behaviour.
    public init(fetcher: UsageFetching, appVersion: String, cacheSeconds: TimeInterval = 180,
                backoffCap: TimeInterval = 3600,
                credentials: CredentialsReading = KeychainCredentialsReader()) {
        self.fetcher = fetcher
        self.credentials = credentials
        self.userAgent = "claude-code/\(appVersion)"
        self.cacheSeconds = cacheSeconds
        self.backoffCap = backoffCap
    }

    /// Explicit `User-Agent`; `nil` omits the header entirely. Brow passes nil.
    public init(fetcher: UsageFetching, userAgent: String?, cacheSeconds: TimeInterval = 180,
                backoffCap: TimeInterval = 3600,
                credentials: CredentialsReading = KeychainCredentialsReader()) {
        self.fetcher = fetcher
        self.credentials = credentials
        self.userAgent = userAgent
        self.cacheSeconds = cacheSeconds
        self.backoffCap = backoffCap
    }

    /// Returns cached usage when fresh (within cacheSeconds of the last success),
    /// is suppressed during a 429 backoff window, else fetches. Throws on 429,
    /// missing credentials, non-2xx, or malformed JSON.
    ///
    /// `force` (the manual refresh button) skips the cache ONLY. The 429 backoff still
    /// applies: a user tapping refresh repeatedly must not be able to punch through a
    /// rate-limit window and earn a longer ban.
    public func usage(configDir: String, now: Date, force: Bool = false) async throws -> OAuthUsage {
        // 1. Fresh cache hit.
        if !force, let entry = cache[configDir], now.timeIntervalSince(entry.at) < cacheSeconds {
            return entry.value
        }

        // 2. Inside a backoff window → suppress without calling the fetcher.
        if let window = backoff[configDir], now < window.until {
            throw OAuthUsageError.backoff
        }

        // 3-5. Read the bearer, fetch, and — if the endpoint rejects the credential —
        //      drop the cached copy and try ONCE more with a freshly read one. Claude
        //      Code rotates its access token on its own schedule (~8h), so a long-lived
        //      cached bearer eventually 401s; without this retry the panel silently
        //      served its last good capture forever.
        var data = Data()
        var status = 0
        for attempt in 0...1 {
            guard let token = credentials.accessToken(configDir: configDir) else {
                throw OAuthUsageError.noCredentials
            }
            (data, status) = try await fetcher.fetch(makeRequest(token: token))
            guard status == 401 || status == 403, attempt == 0 else { break }
            // The bearer was refused: it is stale or revoked. Force the next read past
            // any in-memory cache so the retry carries the current credential.
            credentials.invalidate(configDir: configDir)
        }

        if status == 429 {
            let attempts = backoff[configDir]?.attempts ?? 0
            let delay = min(cacheSeconds * pow(2, Double(attempts)), backoffCap)
            backoff[configDir] = (until: now.addingTimeInterval(delay), attempts: attempts + 1)
            throw OAuthUsageError.tooManyRequests
        }
        guard (200..<300).contains(status) else {
            throw OAuthUsageError.http(status)
        }

        // 6. Parse, cache, reset backoff. The cached value carries the fetch instant, so
        //    a later cache hit still reports when the data was really obtained.
        let usage = try parse(data).stamped(fetchedAt: now)
        cache[configDir] = (at: now, value: usage)
        backoff[configDir] = nil
        return usage
    }

    /// Budget for ONE usage request. `URLRequest`'s default is 60 s and `usage` makes up
    /// to two requests, so an endpoint that accepts the connection and then says nothing
    /// could hold a refresh cycle for two minutes on its own — past the cycle watchdog,
    /// which then abandons a cycle that was only slow, every time, forever. Anthropic
    /// answers this endpoint in well under a second.
    public static let requestTimeout: TimeInterval = 15

    private func makeRequest(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        return request
    }

    private func parse(_ data: Data) throws -> OAuthUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthUsageError.malformed
        }
        func window(_ key: String) -> OAuthWindow? {
            guard let obj = json[key] as? [String: Any] else { return nil }
            let utilization: Double
            if let n = obj["utilization"] as? Double { utilization = n }
            else if let n = obj["utilization"] as? Int { utilization = Double(n) }
            else { return nil }
            let resetsAt = obj["resets_at"] as? String
            return OAuthWindow(utilization: utilization, resetsAt: resetsAt)
        }

        // Parse limits[] for the model-scoped weekly window. The `weekly_scoped` entry
        // carries the per-model bar data (percent, resets_at, scope.model.display_name).
        // Prefer the entry with is_active:true when there are multiple weekly_scoped entries.
        var weeklyScoped: OAuthScopedWindow? = nil
        if let limits = json["limits"] as? [[String: Any]] {
            var candidate: OAuthScopedWindow? = nil
            var candidateIsActive = false
            for entry in limits {
                guard (entry["kind"] as? String) == "weekly_scoped" else { continue }
                let isActive = (entry["is_active"] as? Bool) ?? false
                // Skip inactive entries if we already have an active one.
                if candidateIsActive && !isActive { continue }
                let pct: Double
                if let n = entry["percent"] as? Int { pct = Double(n) }
                else if let n = entry["percent"] as? Double { pct = n }
                else { continue }
                let resetsAt = entry["resets_at"] as? String
                let scope = entry["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let displayName = model?["display_name"] as? String
                candidate = OAuthScopedWindow(utilization: pct, resetsAt: resetsAt,
                                              modelDisplayName: displayName)
                candidateIsActive = isActive
            }
            weeklyScoped = candidate
        }

        return OAuthUsage(
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day"),
            sevenDaySonnet: window("seven_day_sonnet"),
            sevenDayOpus: window("seven_day_opus"),
            sevenDayFable: window("seven_day_fable"),
            weeklyScoped: weeklyScoped
        )
    }
}
