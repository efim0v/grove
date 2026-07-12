import XCTest
import GroveCore

/// Phase 5C-fix — oauthLiveEnabled must default to true so OAuth data flows
/// automatically. Written BEFORE the implementation (TDD RED).
final class OAuthDefaultEnabledTests: XCTestCase {

    func testUsageSettingsDefaultIsOAuthEnabled() {
        let s = UsageSettings()
        XCTAssertTrue(s.oauthLiveEnabled,
                      "oauthLiveEnabled must default to true after Phase 5C-fix")
    }

    func testOldJSONWithoutOauthKeyDecodesAsTrue() throws {
        // Old configs that never wrote oauthLiveEnabled must decode as true
        // (the default now changed from false to true).
        let json = #"{"refreshSeconds":15}"#
        let decoded = try JSONDecoder().decode(UsageSettings.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.oauthLiveEnabled,
                      "absent oauthLiveEnabled key decodes as the new default (true)")
    }

    func testExplicitFalseInJSONIsRespected() throws {
        let json = #"{"refreshSeconds":15,"oauthLiveEnabled":false}"#
        let decoded = try JSONDecoder().decode(UsageSettings.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.oauthLiveEnabled, "explicit false must not be overridden")
    }

    func testExplicitTrueInJSONIsRespected() throws {
        let json = #"{"refreshSeconds":15,"oauthLiveEnabled":true}"#
        let decoded = try JSONDecoder().decode(UsageSettings.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.oauthLiveEnabled)
    }
}
