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
    public init(fiveHour: OAuthWindow?, sevenDay: OAuthWindow?,
                sevenDaySonnet: OAuthWindow?, sevenDayOpus: OAuthWindow?,
                sevenDayFable: OAuthWindow? = nil,
                weeklyScoped: OAuthScopedWindow? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDaySonnet = sevenDaySonnet
        self.sevenDayOpus = sevenDayOpus
        self.sevenDayFable = sevenDayFable
        self.weeklyScoped = weeklyScoped
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
    private let appVersion: String
    private let cacheSeconds: TimeInterval
    private let backoffCap: TimeInterval = 3600

    private var cache: [String: (at: Date, value: OAuthUsage)] = [:]
    private var backoff: [String: (until: Date, attempts: Int)] = [:]

    public init(fetcher: UsageFetching, appVersion: String, cacheSeconds: TimeInterval = 180,
                credentials: CredentialsReading = KeychainCredentialsReader()) {
        self.fetcher = fetcher
        self.credentials = credentials
        self.appVersion = appVersion
        self.cacheSeconds = cacheSeconds
    }

    /// Returns cached usage when fresh (within cacheSeconds of the last success),
    /// is suppressed during a 429 backoff window, else fetches. Throws on 429,
    /// missing credentials, non-2xx, or malformed JSON.
    public func usage(configDir: String, now: Date) async throws -> OAuthUsage {
        // 1. Fresh cache hit.
        if let entry = cache[configDir], now.timeIntervalSince(entry.at) < cacheSeconds {
            return entry.value
        }

        // 2. Inside a backoff window → suppress without calling the fetcher.
        if let window = backoff[configDir], now < window.until {
            throw OAuthUsageError.backoff
        }

        // 3. Read the bearer token (Keychain, then legacy .credentials.json).
        guard let token = credentials.accessToken(configDir: configDir) else {
            throw OAuthUsageError.noCredentials
        }

        // 4. Build the request.
        let request = makeRequest(token: token)

        // 5. Fetch and handle status.
        let (data, status): (Data, Int)
        do {
            (data, status) = try await fetcher.fetch(request)
        } catch {
            throw error
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

        // 6. Parse, cache, reset backoff.
        let usage = try parse(data)
        cache[configDir] = (at: now, value: usage)
        backoff[configDir] = nil
        return usage
    }

    private func makeRequest(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(appVersion)", forHTTPHeaderField: "User-Agent")
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
