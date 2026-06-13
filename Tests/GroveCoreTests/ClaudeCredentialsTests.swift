import XCTest
@testable import GroveCore

final class ClaudeCredentialsTests: XCTestCase {
    typealias K = KeychainCredentialsReader

    // MARK: - service-name scheme (the reverse-engineered Keychain keying)

    func testDefaultAccountUsesBareService() {
        XCTAssertEqual(K.serviceName(configDir: NSHomeDirectory() + "/.claude"),
                       "Claude Code-credentials")
        // A tilde must expand to the same thing.
        XCTAssertEqual(K.serviceName(configDir: "~/.claude"), "Claude Code-credentials")
    }

    func testCustomAccountUsesSha256SuffixedService() {
        // Regression vector confirmed against a real install: the custom config dir
        // "/Users/demo/.claude-accounts/work-account" keys the Keychain item
        // "Claude Code-credentials-a0e8383e". This pins the exact scheme (first 8 hex
        // of sha256(expanded dir, no trailing slash)) so it can't silently drift.
        XCTAssertEqual(
            K.serviceName(configDir: "/Users/demo/.claude-accounts/work-account"),
            "Claude Code-credentials-a0e8383e")
    }

    func testTrailingSlashDoesNotChangeTheService() {
        XCTAssertEqual(
            K.serviceName(configDir: "/Users/demo/.claude-accounts/work-account/"),
            K.serviceName(configDir: "/Users/demo/.claude-accounts/work-account"))
    }

    func testSuffixedServiceShapeForAnArbitraryDir() {
        let name = K.serviceName(configDir: "/tmp/some-account")
        XCTAssertTrue(name.hasPrefix("Claude Code-credentials-"))
        let suffix = name.dropFirst("Claude Code-credentials-".count)
        XCTAssertEqual(suffix.count, 8)
        XCTAssertTrue(suffix.allSatisfy { $0.isHexDigit })
    }

    // MARK: - token parsing (Keychain blob == legacy .credentials.json shape)

    func testParseTokenFromClaudeAiOauth() {
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"abc","refreshToken":"r"}}"#.utf8)
        XCTAssertEqual(K.parseToken(blob), "abc")
    }

    func testParseTokenFromTopLevel() {
        XCTAssertEqual(K.parseToken(Data(#"{"accessToken":"xyz"}"#.utf8)), "xyz")
    }

    func testParseTokenRejectsEmptyOrMissingOrMalformed() {
        XCTAssertNil(K.parseToken(Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)))
        XCTAssertNil(K.parseToken(Data(#"{"claudeAiOauth":{"nope":1}}"#.utf8)))
        XCTAssertNil(K.parseToken(Data("not json".utf8)))
    }

    // MARK: - file fallback (older installs)

    func testAccessTokenFallsBackToCredentialsFile() throws {
        let dir = try Fixture.tempDir("creds")
        try #"{"claudeAiOauth":{"accessToken":"file-tok"}}"#
            .write(to: dir.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        // The Keychain lookup for this unique temp path misses (no prompt), so the
        // reader falls back to the file.
        XCTAssertEqual(K().accessToken(configDir: dir.path), "file-tok")
    }

    func testAccessTokenNilWhenNothingAvailable() throws {
        let dir = try Fixture.tempDir("creds-empty")
        XCTAssertNil(K().accessToken(configDir: dir.path))
    }
}
