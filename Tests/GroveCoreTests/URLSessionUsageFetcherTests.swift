import XCTest
@testable import GroveCore

/// The production fetcher keeps nothing about a usage or profile request, and the first
/// request of a launch empties the shared URL cache earlier builds sent them through.
/// Nothing here reaches the network, `URLSession.shared` or `URLCache.shared`:
/// `CannedHTTP` answers every request in-process, and every cache is a fresh one in a
/// temporary directory.
final class URLSessionUsageFetcherTests: XCTestCase {
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    private struct Creds: CredentialsReading {
        let value: String
        func token(configDir: String) -> ClaudeToken? { ClaudeToken(value: value, expiresAt: nil) }
    }

    func testTheSessionKeepsNoCacheCookiesOrCredentials() {
        let configuration = URLSessionUsageFetcher.session.configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
    }

    /// Brow builds two fetchers, one for usage and one for the profile. Both use the one
    /// session (not `URLSession.shared`) and the one purge (not one per fetcher).
    func testEveryDefaultFetcherSharesTheSessionAndThePurge() {
        let usage = URLSessionUsageFetcher()
        let profile = URLSessionUsageFetcher()
        XCTAssertIdentical(usage.session, URLSessionUsageFetcher.session)
        XCTAssertIdentical(profile.session, URLSessionUsageFetcher.session)
        XCTAssertIdentical(usage.purge, URLSessionUsageFetcher.sharedCachePurge)
        XCTAssertIdentical(profile.purge, URLSessionUsageFetcher.sharedCachePurge)
    }

    /// The requests both clients build, each with its bearer, go through the fetcher's
    /// settings applied on top of a configuration that has a disk cache, and nothing
    /// reaches that cache. A control request through the configuration as it is IS
    /// stored, bearer included, so the cache would show a request the settings let through.
    func testTheClientsRequestsAreNotStoredInACache() async throws {
        let dir = try Fixture.tempDir("usage-fetcher-cache")
        let cache = URLCache(memoryCapacity: 0, diskCapacity: 10 << 20, directory: dir)
        let session = URLSession(configuration: URLSessionUsageFetcher.configuration(
            from: CannedHTTP.configuration(cache: cache)))
        defer { session.finishTasksAndInvalidate() }
        let fetcher = URLSessionUsageFetcher(session: session, purge: nil)

        let usage = try await OAuthUsageClient(fetcher: fetcher, userAgent: nil, credentials: Creds(value: "usage-token"))
            .usage(configDir: "/d", now: Date())
        _ = try await OAuthProfileClient(fetcher: fetcher, userAgent: nil, credentials: Creds(value: "profile-token"))
            .profile(configDir: "/d")
        XCTAssertEqual(usage.fiveHour?.utilization, 10, "the canned answer came back")
        XCTAssertEqual(CannedHTTP.authorization(for: usageURL), "Bearer usage-token")
        XCTAssertEqual(CannedHTTP.authorization(for: profileURL), "Bearer profile-token")
        XCTAssertNil(cache.cachedResponse(for: URLRequest(url: usageURL)))
        XCTAssertNil(cache.cachedResponse(for: URLRequest(url: profileURL)))

        // Control. Once its entry is on disk, anything stored before it has had at least
        // as long to get there.
        let control = URLSession(configuration: CannedHTTP.configuration(cache: cache))
        defer { control.finishTasksAndInvalidate() }
        var request = URLRequest(url: URL(string: "https://example.test/control")!)
        request.setValue("Bearer control-token", forHTTPHeaderField: "Authorization")
        _ = try await control.data(for: request)
        XCTAssertNotNil(cache.cachedResponse(for: request), "the canned answer is one a cache stores")
        try await waitUntil("the control entry on disk") { Self.files(in: dir, contain: "control-token") }
        XCTAssertFalse(Self.files(in: dir, contain: "usage-token"))
        XCTAssertFalse(Self.files(in: dir, contain: "profile-token"))
    }

    /// What an earlier build left behind: the usage request in the app's URL cache, bearer
    /// and all. The first fetch empties that cache, its files on disk included, and only
    /// the first: later requests, and other fetchers sharing the purge, leave it alone.
    func testTheFirstFetchEmptiesTheOldCacheOnce() async throws {
        let dir = try Fixture.tempDir("usage-fetcher-old-cache")
        let old = URLCache(memoryCapacity: 0, diskCapacity: 10 << 20, directory: dir)
        var stored = URLRequest(url: usageURL)
        stored.setValue("Bearer old-token", forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(url: usageURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        old.storeCachedResponse(CachedURLResponse(response: response, data: Data("{}".utf8)), for: stored)
        try await waitUntil("the old entry on disk") { Self.files(in: dir, contain: "old-token") }

        let opened = Counter()
        let purge = URLSessionUsageFetcher.CachePurge { opened.increment(); return old }
        let session = URLSession(configuration: URLSessionUsageFetcher.configuration(from: CannedHTTP.configuration()))
        defer { session.finishTasksAndInvalidate() }
        let usage = URLSessionUsageFetcher(session: session, purge: purge)
        let profile = URLSessionUsageFetcher(session: session, purge: purge)
        XCTAssertEqual(opened.value, 0, "nothing is touched before the first request")

        _ = try await usage.fetch(URLRequest(url: usageURL))
        _ = try await profile.fetch(URLRequest(url: profileURL))
        _ = try await usage.fetch(URLRequest(url: usageURL))
        XCTAssertEqual(opened.value, 1, "once per launch, not per request or per fetcher")
        try await waitUntil("the old entry gone") { old.cachedResponse(for: stored) == nil }
        try await waitUntil("the old bearer gone from disk") { !Self.files(in: dir, contain: "old-token") }
    }

    // MARK: - helpers

    /// Whether any file under `dir` (Cache.db, its write-ahead log, fsCachedData) holds `needle`.
    private static func files(in dir: URL, contain needle: String) -> Bool {
        let bytes = Data(needle.utf8)
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if let data = try? Data(contentsOf: url), data.range(of: bytes) != nil { return true }
        }
        return false
    }

    /// Polls `condition` until it holds or the timeout passes. A URL cache writes to disk,
    /// and empties, asynchronously: a few tens of milliseconds after the call.
    private func waitUntil(_ what: String, timeout: TimeInterval = 10,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)", file: file, line: line); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Answers every request in-process with a 200 a URL cache may store, and a usage body
/// both clients parse. Remembers the Authorization header each URL arrived with.
private final class CannedHTTP: URLProtocol {
    private static let seen = Seen()

    static func authorization(for url: URL) -> String? { seen.value(for: url) }

    /// An ephemeral configuration that sends every request here, with `cache` as its URL cache.
    static func configuration(cache: URLCache? = nil) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = cache
        configuration.protocolClasses = [CannedHTTP.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.seen.set(request.value(forHTTPHeaderField: "Authorization"), for: url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json",
                                                      "Cache-Control": "max-age=3600"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: Data(#"{"five_hour":{"utilization":10}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var headers: [URL: String] = [:]
        func set(_ value: String?, for url: URL) { lock.withLock { headers[url] = value } }
        func value(for url: URL) -> String? { lock.withLock { headers[url] } }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
