import XCTest
@testable import GroveCore

/// Unit tests for the Data/Prose classification metadata on `CodeStatsEngine`. The
/// line classifier itself is unchanged (covered by CodeStatsClassifyTests); this only
/// pins which language NAMES count as Data/Prose vs Code.
final class CodeStatsEngineTests: XCTestCase {

    func testDataProseLanguagesClassification() {
        // The four canonical data/prose languages.
        XCTAssertTrue(CodeStatsEngine.isDataProse("Markdown"))
        XCTAssertTrue(CodeStatsEngine.isDataProse("JSON"))
        XCTAssertTrue(CodeStatsEngine.isDataProse("YAML"))
        XCTAssertTrue(CodeStatsEngine.isDataProse("TOML"))
        // Everything else is Code.
        XCTAssertFalse(CodeStatsEngine.isDataProse("Swift"))
        XCTAssertFalse(CodeStatsEngine.isDataProse("Dart"))
        XCTAssertFalse(CodeStatsEngine.isDataProse("Python"))
        XCTAssertFalse(CodeStatsEngine.isDataProse("TypeScript/JavaScript"))
    }

    func testIsDataProseRobustToUnknownNames() {
        XCTAssertFalse(CodeStatsEngine.isDataProse(""))
        XCTAssertFalse(CodeStatsEngine.isDataProse("markdown"), "case-sensitive: must match table name exactly")
        XCTAssertFalse(CodeStatsEngine.isDataProse("Brainfuck"))
    }

    func testDataProseNamesExistInLanguageTable() {
        // Guard against a typo: every data/prose name must be a real table entry.
        let tableNames = Set(CodeStatsEngine.languageTable.map(\.name))
        for name in CodeStatsEngine.dataProseLanguages {
            XCTAssertTrue(tableNames.contains(name), "\(name) is not a languageTable entry")
        }
    }
}
