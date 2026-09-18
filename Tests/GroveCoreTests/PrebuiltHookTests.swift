import XCTest
@testable import GroveCore

final class PrebuiltHookTests: XCTestCase {
    private var importHook: PrebuiltHook {
        PrebuiltHook.all.first { $0.id == "import-claude-md" }!
    }

    private func tempDir() -> String {
        let dir = NSTemporaryDirectory() + "grove-prebuilt-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func testStatusUnavailableWhenFileMissing() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let status = importHook.status(projectPath: dir)
        XCTAssertFalse(status.isReady)
        XCTAssertNotNil(status.reason)
    }

    func testStatusReadyWhenFilePresent() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: dir + "/CLAUDE.md", contents: Data("# hi".utf8))
        XCTAssertTrue(importHook.status(projectPath: dir).isReady)
        XCTAssertNil(importHook.status(projectPath: dir).reason)
    }

    func testInstallIsIdempotentAndInstallsTheSeed() {
        var project = ProjectConfig(name: "p", path: "/tmp/p")
        XCTAssertFalse(importHook.isInstalled(in: project))
        importHook.install(into: &project)
        XCTAssertTrue(importHook.isInstalled(in: project))
        XCTAssertEqual(project.seedFiles.count, 1)
        XCTAssertEqual(project.seedFiles.first?.source, "CLAUDE.md")
        XCTAssertEqual(project.seedFiles.first?.mode, .copy)
        XCTAssertEqual(project.seedFiles.first?.dest, .umbrella)
        // Second install must not duplicate.
        importHook.install(into: &project)
        XCTAssertEqual(project.seedFiles.count, 1)
    }

    func testRemoveClearsTheSeed() {
        var project = ProjectConfig(name: "p", path: "/tmp/p")
        importHook.install(into: &project)
        importHook.remove(from: &project)
        XCTAssertFalse(importHook.isInstalled(in: project))
        XCTAssertTrue(project.seedFiles.isEmpty)
    }
}
