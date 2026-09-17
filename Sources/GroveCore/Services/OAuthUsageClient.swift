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

public struct OAuthWindow: Sendable, Equatable, Codable {
    public let utilization: Double
    public let resetsAt: String?
    public init(utilization: Double, resetsAt: String?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

/// A model-scoped weekly window from the `limits[]` `weekly_scoped` entry.
public struct OAuthScopedWindow: Sendable, Equatable, Codable {
    public let utilization: Double
    public let resetsAt: String?
    public let modelDisplayName: String?
    public init(utilization: Double, resetsAt: String?, modelDisplayName: String?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.modelDisplayName = modelDisplayName
    }
}

public struct OAuthUsage: Sendable, Equatable, Codable {
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

    /// What the endpoint really enforces, measured on 2026-09-17 against a Max account
    /// (single token, curl, ~30 requests): a token bucket PER TOKEN — one 200 per
    /// ~90–100 s of refill, a burst of five after a long rest, `retry-after: 0` on every
    /// 429, and 429s that do not extend the penalty (the next 200 arrived 88 s after the
    /// previous one through thirteen refusals). Two accounts are two independent buckets.
    /// `minInterval` is the refill period the pacing is built on; `burstCapacity` is
    /// how many manual refreshes a rested account can absorb before it has to wait.
    private let minInterval: TimeInterval
    private let burstCapacity: Double
    /// True when every config dir draws on ONE bucket (the limit is per user or per
    /// machine rather than per token): the pacing state is then kept under a single
    /// key, so a success for one account is the last success for all of them.
    private let sharedBucket: Bool
    private func pacingKey(_ configDir: String) -> String { sharedBucket ? "*" : configDir }
    /// Cross-process view of the bucket (see `UsagePacingLedger`). nil = this process
    /// is the only client of the endpoint, as in tests.
    private let ledger: UsagePacingLedger?

    private var cache: [String: (at: Date, value: OAuthUsage)] = [:]
    private var backoff: [String: (until: Date, attempts: Int)] = [:]
    /// Per-dir pacing state: when the endpoint last answered 200, and the estimated
    /// bucket level (refilled at 1 per `minInterval`, capped at `burstCapacity`).
    private var pacing: [String: (lastSuccessAt: Date, level: Double, levelAt: Date)] = [:]

    /// Identifies as `claude-code/<appVersion>` — Grove's long-standing behaviour.
    public init(fetcher: UsageFetching, appVersion: String, cacheSeconds: TimeInterval = 180,
                backoffCap: TimeInterval = 3600, minInterval: TimeInterval = 100, burstCapacity: Int = 5,
                sharedBucket: Bool = false, ledger: UsagePacingLedger? = nil,
                credentials: CredentialsReading = KeychainCredentialsReader()) {
        self.fetcher = fetcher
        self.credentials = credentials
        self.userAgent = "claude-code/\(appVersion)"
        self.ledger = ledger
        self.cacheSeconds = cacheSeconds
        self.backoffCap = backoffCap
        self.minInterval = minInterval
        self.burstCapacity = Double(max(1, burstCapacity))
        self.sharedBucket = sharedBucket
    }

    /// Explicit `User-Agent`; `nil` omits the header entirely. Brow passes nil.
    public init(fetcher: UsageFetching, userAgent: String?, cacheSeconds: TimeInterval = 180,
                backoffCap: TimeInterval = 3600, minInterval: TimeInterval = 100, burstCapacity: Int = 5,
                sharedBucket: Bool = false, ledger: UsagePacingLedger? = nil,
                credentials: CredentialsReading = KeychainCredentialsReader()) {
        self.fetcher = fetcher
        self.credentials = credentials
        self.userAgent = userAgent
        self.ledger = ledger
        self.cacheSeconds = cacheSeconds
        self.backoffCap = backoffCap
        self.minInterval = minInterval
        self.burstCapacity = Double(max(1, burstCapacity))
        self.sharedBucket = sharedBucket
    }

    /// The earliest instant a request for `configDir` would actually be sent. `now`
    /// when one would go out right away. A background poll (`force: false`) also waits
    /// for `minInterval` since the last success so it never drains the burst budget the
    /// refresh button relies on; the button (`force: true`) only needs a token in the
    /// bucket. After a 429 both wait for the backoff window.
    public func nextAllowedAt(configDir: String, force: Bool, now: Date) -> Date {
        adoptLedger(configDir: configDir)
        var earliest = now
        if let window = backoff[configDir], now < window.until { earliest = max(earliest, window.until) }
        guard let p = pacing[pacingKey(configDir)] else { return earliest }
        if !force {
            earliest = max(earliest, p.lastSuccessAt.addingTimeInterval(minInterval))
        } else if Self.level(p, now: now, refill: minInterval, cap: burstCapacity) < 1 {
            // Empty bucket: the next token lands one refill period after the level was
            // last measured, minus what has already accrued.
            let accrued = Self.level(p, now: now, refill: minInterval, cap: burstCapacity)
            earliest = max(earliest, now.addingTimeInterval((1 - accrued) * minInterval))
        }
        return earliest
    }

    private static func level(_ p: (lastSuccessAt: Date, level: Double, levelAt: Date),
                              now: Date, refill: TimeInterval, cap: Double) -> Double {
        min(cap, p.level + max(0, now.timeIntervalSince(p.levelAt)) / refill)
    }

    /// Take whatever another process learned since we last looked: a later success
    /// (with the bucket it left and the reading it got — that reading is served
    /// instead of spending a request of our own), or a 429 window still open. Our own
    /// state wins whenever it is newer, so this never rewinds the clock.
    private func adoptLedger(configDir: String) {
        guard let ledger else { return }
        let records = ledger.load()
        let key = pacingKey(configDir)
        let bucket = sharedBucket
            ? records.values.max(by: { $0.lastSuccessAt < $1.lastSuccessAt })
            : records[configDir]
        if let r = bucket, pacing[key].map({ $0.lastSuccessAt < r.lastSuccessAt }) ?? true {
            pacing[key] = (lastSuccessAt: r.lastSuccessAt, level: r.level, levelAt: r.levelAt)
        }
        guard let mine = records[configDir] else { return }
        if let until = mine.backoffUntil, (backoff[configDir]?.until ?? .distantPast) < until {
            backoff[configDir] = (until: until, attempts: mine.attempts)
        }
        if let reading = mine.reading, let at = reading.fetchedAt,
           (cache[configDir]?.at ?? .distantPast) < at {
            cache[configDir] = (at: at, value: reading)
        }
    }

    private func publishLedger(configDir: String) {
        guard let ledger, let p = pacing[pacingKey(configDir)] else { return }
        let window = backoff[configDir]
        ledger.store(UsagePacingRecord(lastSuccessAt: p.lastSuccessAt, level: p.level, levelAt: p.levelAt,
                                       backoffUntil: window?.until, attempts: window?.attempts ?? 0,
                                       reading: cache[configDir]?.value), for: configDir)
    }

    /// Tell the client about a reading obtained BEFORE this process started (the
    /// persisted snapshot), so a relaunch does not spend a fresh request on every
    /// account inside the window the previous run already used — four relaunches in
    /// ten minutes drained both buckets and every one of them opened on "rate
    /// limited". Ignored when the client already knows a later success for the dir.
    public func seedLastSuccess(configDir: String, at: Date) {
        let key = pacingKey(configDir)
        if let p = pacing[key], p.lastSuccessAt >= at { return }
        // The level is unknown: assume EMPTY as of the reading and let it refill. A
        // full burst on every launch is what made three relaunches in a row open on
        // 429 — the real bucket had been drained by the launches before.
        pacing[key] = (lastSuccessAt: at, level: 0, levelAt: at)
    }

    /// Returns cached usage when fresh (within cacheSeconds of the last success),
    /// is suppressed during a 429 backoff window, else fetches. Throws on 429,
    /// missing credentials, non-2xx, or malformed JSON.
    ///
    /// `force` (the manual refresh button) skips the cache ONLY. The 429 backoff still
    /// applies: a user tapping refresh repeatedly must not be able to punch through a
    /// rate-limit window and earn a longer ban. Between backoffs the endpoint's own
    /// pacing applies (see `minInterval`): a background poll that arrives before the
    /// window has re-opened is answered from the cache — it is the freshest reading
    /// there can be, not an error — and a forced refresh with an empty burst budget
    /// throws `.backoff` so the caller can schedule itself for `nextAllowedAt`.
    public func usage(configDir: String, now: Date, force: Bool = false) async throws -> OAuthUsage {
        adoptLedger(configDir: configDir)
        // 1. Fresh cache hit.
        if !force, let entry = cache[configDir], now.timeIntervalSince(entry.at) < cacheSeconds {
            return entry.value
        }

        // 2. Inside a backoff window → suppress without calling the fetcher. A
        //    background poll that holds a reading is answered with that reading — being
        //    told to wait is not an error about the account, and a "rate limited" tag on
        //    every poll for the length of the window was exactly that lie. A FORCED
        //    request still throws so the caller can queue itself for `nextAllowedAt`.
        if let window = backoff[configDir], now < window.until {
            if !force, let entry = cache[configDir] { return entry.value }
            throw OAuthUsageError.backoff
        }

        // 2b. Endpoint pacing. A background poll inside the refill period is served
        //     from the cache; a forced refresh with nothing left in the bucket waits.
        if let p = pacing[pacingKey(configDir)] {
            if !force, now.timeIntervalSince(p.lastSuccessAt) < minInterval {
                if let entry = cache[configDir] { return entry.value }
                throw OAuthUsageError.backoff      // seeded from disk, nothing in memory yet
            }
            if force, Self.level(p, now: now, refill: minInterval, cap: burstCapacity) < 1 {
                throw OAuthUsageError.backoff
            }
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
            let until: Date
            if let p = pacing[pacingKey(configDir)] {
                if now.timeIntervalSince(p.lastSuccessAt) < minInterval {
                    // Asked too early: the next token lands one refill period after the
                    // last success, and never sooner than 30 s from now.
                    until = max(p.lastSuccessAt.addingTimeInterval(minInterval), now.addingTimeInterval(30))
                } else {
                    // Refused AFTER a full refill period: our picture of the bucket is
                    // wrong (something else drains it — another client, a shared limit).
                    // Back off exponentially from 30 s instead of knocking every 30 s.
                    until = now.addingTimeInterval(min(30 * pow(2, Double(attempts)), backoffCap))
                }
                // Empty as of the LAST SUCCESS, not as of now: the server's refill clock
                // runs from the 200 it gave us, and the 429s in between do not reset it
                // (measured: the next 200 arrived 88 s after the previous one through
                // thirteen refusals). Dating the empty bucket from the 429 would push
                // `nextAllowedAt` a full period past the moment the window really opens.
                pacing[pacingKey(configDir)] = (lastSuccessAt: p.lastSuccessAt, level: 0, levelAt: p.lastSuccessAt)
            } else {
                // Nothing known yet: exponential from the cache period, capped.
                until = now.addingTimeInterval(min(cacheSeconds * pow(2, Double(attempts)), backoffCap))
            }
            backoff[configDir] = (until: until, attempts: attempts + 1)
            publishLedger(configDir: configDir)
            throw OAuthUsageError.tooManyRequests
        }
        guard (200..<300).contains(status) else {
            throw OAuthUsageError.http(status)
        }

        // 6. Parse, cache, reset backoff, spend one bucket token. The cached value
        //    carries the fetch instant, so a later cache hit still reports when the
        //    data was really obtained.
        let usage = try parse(data).stamped(fetchedAt: now)
        cache[configDir] = (at: now, value: usage)
        backoff[configDir] = nil
        let level = pacing[pacingKey(configDir)].map { Self.level($0, now: now, refill: minInterval, cap: burstCapacity) }
            ?? burstCapacity
        pacing[pacingKey(configDir)] = (lastSuccessAt: now, level: max(0, level - 1), levelAt: now)
        publishLedger(configDir: configDir)
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
