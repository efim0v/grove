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
}

public struct OAuthUsage: Sendable, Equatable {
    public let fiveHour: OAuthWindow?
    public let sevenDay: OAuthWindow?
    public let sevenDaySonnet: OAuthWindow?
    public let sevenDayOpus: OAuthWindow?
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
    private let appVersion: String
    private let cacheSeconds: TimeInterval
    private let backoffCap: TimeInterval = 3600

    private var cache: [String: (at: Date, value: OAuthUsage)] = [:]
    private var backoff: [String: (until: Date, attempts: Int)] = [:]

    public init(fetcher: UsageFetching, appVersion: String, cacheSeconds: TimeInterval = 180) {
        self.fetcher = fetcher
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

        // 3. Read the bearer token from <configDir>/.credentials.json.
        let token = try readAccessToken(configDir: configDir)

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

    private func readAccessToken(configDir: String) throws -> String {
        let path = configDir + "/.credentials.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw OAuthUsageError.noCredentials }

        if let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            return token
        }
        // Defensively also accept a top-level accessToken.
        if let token = json["accessToken"] as? String, !token.isEmpty {
            return token
        }
        throw OAuthUsageError.noCredentials
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
        return OAuthUsage(
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day"),
            sevenDaySonnet: window("seven_day_sonnet"),
            sevenDayOpus: window("seven_day_opus")
        )
    }
}
