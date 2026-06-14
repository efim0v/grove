import Foundation
import XCTest
@testable import GroveCore

final class CodeStatsScannerTests: XCTestCase {
    private let scanner = CodeStatsScanner()

    // MARK: - Fixture builder

    private func write(_ url: URL, _ contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Builds this tree under <tmp>/project:
    ///
    ///     main.swift              counted (Swift)
    ///     util.py                 counted (Python)
    ///     README.md               counted (Markdown)
    ///     notes.txt               unknown extension -> skipped from counts
    ///     secret.swift            ignored by .gitignore
    ///     generated.swift         ignored by .ignorestats
    ///     blob.bin                NUL byte -> binary, skipped
    ///     .gitignore              "secret.swift"
    ///     .ignorestats            "generated.swift"
    ///     vendor/lib.swift        excluded via extraIgnoredFolders
    ///     .worktrees/wt.swift     under always-skipped dir
    ///     node_modules/pkg.js     under always-skipped dir
    ///     sub/deep.swift          counted (nested)
    private func makeProjectTree() throws -> URL {
        let tmp = try Fixture.tempDir("codestats-scan")
        let project = tmp.appendingPathComponent("project")
        let fm = FileManager.default
        try fm.createDirectory(at: project, withIntermediateDirectories: true)

        // 3 lines of code, 1 comment, 1 blank.
        try write(project.appendingPathComponent("main.swift"),
                  "import Foundation\n// a comment\n\nlet x = 1\nprint(x)\n")
        // 1 code, 1 comment, 0 blank.
        try write(project.appendingPathComponent("util.py"),
                  "# hello\nvalue = 2\n")
        // Markdown: 2 non-blank -> code (no comment syntax).
        try write(project.appendingPathComponent("README.md"),
                  "# Title\n\nbody\n")
        // Unknown extension: never counted.
        try write(project.appendingPathComponent("notes.txt"),
                  "just some text\nmore text\n")
        // Ignored by .gitignore / .ignorestats.
        try write(project.appendingPathComponent("secret.swift"), "let s = 1\n")
        try write(project.appendingPathComponent("generated.swift"), "let g = 1\nlet g2 = 2\n")
        try write(project.appendingPathComponent(".gitignore"), "secret.swift\n")
        try write(project.appendingPathComponent(".ignorestats"), "generated.swift\n")

        // Binary file with a .swift extension but a NUL byte -> skippedBinary.
        let binURL = project.appendingPathComponent("blob.swift")
        try Data([0x6c, 0x65, 0x74, 0x00, 0x78]).write(to: binURL)

        // Folder excluded via extraIgnoredFolders.
        try write(project.appendingPathComponent("vendor/lib.swift"), "let v = 1\nlet v2 = 2\n")
        // Always-skipped infrastructure dirs.
        try write(project.appendingPathComponent(".worktrees/wt.swift"), "let w = 1\n")
        try write(project.appendingPathComponent("node_modules/pkg.js"), "const a = 1;\n")
        // Nested counted file.
        try write(project.appendingPathComponent("sub/deep.swift"), "let d = 1\n")

        return project
    }

    // MARK: - Totals

    func testScanExcludesIgnoredWorktreeBinaryAndUnknownExtensions() throws {
        let project = try makeProjectTree()
        var cache: [String: CachedFile] = [:]
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stats = scanner.scan(projectPath: project.path,
                                 extraIgnoredFolders: ["vendor"],
                                 now: now, cache: &cache)

        // Counted files: main.swift, util.py, README.md, sub/deep.swift.
        XCTAssertEqual(stats.totalFiles, 4)
        XCTAssertEqual(stats.scannedAt, now)
        // blob.swift is binary -> one skippedBinary.
        XCTAssertEqual(stats.skippedBinary, 1)

        // Languages: Swift (main + deep), Python (util), Markdown (README). NO
        // TypeScript/JavaScript (node_modules excluded), nothing from vendor/.worktrees.
        let langs = Set(stats.byLanguage.map(\.language))
        XCTAssertEqual(langs, ["Swift", "Python", "Markdown"])

        // Swift: main.swift (3 code, 1 comment, 1 blank) + deep.swift (1 code).
        let swift = try XCTUnwrap(stats.byLanguage.first { $0.language == "Swift" })
        XCTAssertEqual(swift.files, 2)
        XCTAssertEqual(swift.code, 4)
        XCTAssertEqual(swift.comment, 1)
        XCTAssertEqual(swift.blank, 1)
        XCTAssertEqual(swift.total, 6)

        // Python: util.py (1 code, 1 comment).
        let python = try XCTUnwrap(stats.byLanguage.first { $0.language == "Python" })
        XCTAssertEqual(python.files, 1)
        XCTAssertEqual(python.code, 1)
        XCTAssertEqual(python.comment, 1)

        // Whole-scan totals are the sum over counted files.
        XCTAssertEqual(stats.code, swift.code + python.code + 2)   // +2 markdown code lines
        XCTAssertEqual(stats.totalLines, stats.code + stats.comment + stats.blank)

        // byLanguage is sorted DESC by code.
        XCTAssertEqual(stats.byLanguage.map(\.code), stats.byLanguage.map(\.code).sorted(by: >))
    }

    // MARK: - Cache short-circuit

    func testMtimeCacheShortCircuitsSecondScan() throws {
        let project = try makeProjectTree()
        var cache: [String: CachedFile] = [:]

        let first = scanner.scan(projectPath: project.path,
                                 extraIgnoredFolders: ["vendor"], cache: &cache)
        XCTAssertFalse(cache.isEmpty)
        // The cache holds exactly the counted files (binary/unknown/ignored never enter).
        XCTAssertEqual(cache.count, first.totalFiles)

        // A second scan with the populated cache must produce identical stats.
        let mainPath = project.appendingPathComponent("main.swift").path
        let cachedMain = try XCTUnwrap(cache[mainPath])

        let second = scanner.scan(projectPath: project.path,
                                  extraIgnoredFolders: ["vendor"], cache: &cache)
        XCTAssertEqual(second.totalFiles, first.totalFiles)
        XCTAssertEqual(second.code, first.code)
        XCTAssertEqual(second.comment, first.comment)
        XCTAssertEqual(second.blank, first.blank)
        XCTAssertEqual(second.byLanguage, first.byLanguage)

        // Same (mtime,size) -> the cached entry survives untouched (the short-circuit).
        XCTAssertEqual(cache[mainPath], cachedMain)
    }

    func testCacheReReadsAfterFileChanges() throws {
        let project = try makeProjectTree()
        var cache: [String: CachedFile] = [:]
        _ = scanner.scan(projectPath: project.path, extraIgnoredFolders: ["vendor"], cache: &cache)

        // Append a code line to main.swift, then bump its mtime forward so the
        // (mtime,size) key changes and the cache MUST re-read it.
        let mainURL = project.appendingPathComponent("main.swift")
        try "import Foundation\n// a comment\n\nlet x = 1\nprint(x)\nlet y = 2\n"
            .write(to: mainURL, atomically: true, encoding: .utf8)
        let future = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: mainURL.path)

        let after = scanner.scan(projectPath: project.path,
                                 extraIgnoredFolders: ["vendor"], cache: &cache)
        let swift = try XCTUnwrap(after.byLanguage.first { $0.language == "Swift" })
        XCTAssertEqual(swift.code, 5, "the appended code line should be re-read and counted")
    }

    // MARK: - Directory skeleton

    func testDirectoryTreeEmitsFoldersSkippingInfraDirsAndFiles() throws {
        let project = try makeProjectTree()
        let root = scanner.directoryTree(projectPath: project.path)

        // Root carries an empty relativePath; only DIRECTORIES become children.
        XCTAssertEqual(root.relativePath, "")
        let topLevel = root.children.map(\.name).sorted()
        // sub/ and vendor/ are present; node_modules + .worktrees are always-skipped;
        // no files (main.swift, etc.) appear in the skeleton.
        XCTAssertEqual(topLevel, ["sub", "vendor"])

        let vendor = try XCTUnwrap(root.children.first { $0.name == "vendor" })
        XCTAssertEqual(vendor.relativePath, "vendor")
        XCTAssertTrue(vendor.children.isEmpty)   // vendor only holds files
    }

    func testCacheDropsDeletedFiles() throws {
        let project = try makeProjectTree()
        var cache: [String: CachedFile] = [:]
        _ = scanner.scan(projectPath: project.path, extraIgnoredFolders: ["vendor"], cache: &cache)
        let before = cache.count

        try FileManager.default.removeItem(at: project.appendingPathComponent("sub/deep.swift"))
        let after = scanner.scan(projectPath: project.path,
                                 extraIgnoredFolders: ["vendor"], cache: &cache)
        XCTAssertEqual(cache.count, before - 1, "deleted file must drop out of the cache")
        XCTAssertEqual(after.totalFiles, before - 1)
    }
}
