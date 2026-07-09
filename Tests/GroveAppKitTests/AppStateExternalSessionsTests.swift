import XCTest
import GroveCore
@testable import GroveAppKit

/// Tests for AppState.externalSessionsByProject / otherSessions.
/// These are the Phase 2 / Task 2 attribution indices: disk-wide session scan
/// attributed to projects via owningProject(forCwd:).
@MainActor
final class AppStateExternalSessionsTests: XCTestCase {

    // MARK: - Helpers

    private var root: URL!
    private var configURL: URL!

    override func setUp() async throws {
        root = try FixtureLite.tempDir("appstate-external-sessions")
        configURL = root.appendingPathComponent("config.json")
    }

    private func makeState() -> AppState {
        let state = AppState(configStore: ConfigStore(url: configURL))
        // Point canonicalDir into temp space so prefix matching is predictable.
        state.canonicalDirOverride = root.appendingPathComponent("canonical").path
        // Point cmux hook file at a non-existent path (no cmux in these tests).
        state.cmuxHookFile = root.appendingPathComponent("no-hook.json").path
        return state
    }

    /// Write a minimal JSONL transcript into `configDir/projects/<mangle(cwd)>/<id>.jsonl`.
    /// Returns the file URL so the caller can back-date it if needed.
    @discardableResult
    private func writeTranscript(
        configDir: URL,
        cwd: String,
        sessionId: String,
        title: String = "Test session"
    ) throws -> URL {
        let dir = configDir
            .appendingPathComponent("projects")
            .appendingPathComponent(ClaudeService.mangle(cwd))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","cwd":"\#(cwd)","sessionId":"\#(sessionId)","gitBranch":"main"}"#,
            #"{"type":"ai-title","aiTitle":"\#(title)"}"#,
        ]
        let fileURL = dir.appendingPathComponent("\(sessionId).jsonl")
        try lines.joined(separator: "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    // MARK: - Case 1: Attributes under matching project (path prefix)

    func testSessionUnderProjectPathLandsInExternalSessionsByProject() async throws {
        let configDir = try FixtureLite.tempDir("ext-case1-config")
        let projectPath = "/Users/x/Projects/alpha"
        let sessionCwd = projectPath + "/feature-x"

        try writeTranscript(configDir: configDir, cwd: sessionCwd, sessionId: "s-alpha-1")

        let state = makeState()
        let project = ProjectConfig(name: "alpha", path: projectPath)
        state.config.projects = [project]
        state.config.accounts = [AccountConfig(name: "default", configDir: configDir.path)]

        await state.refreshSessionIndex()

        // Must appear in externalSessionsByProject under the matching project.
        let bucket = state.externalSessionsByProject[project.id] ?? []
        XCTAssertEqual(bucket.map(\.id), ["s-alpha-1"],
                       "Session whose cwd is under project.path must land in externalSessionsByProject")

        // Must NOT appear in otherSessions.
        XCTAssertFalse(state.otherSessions.map(\.id).contains("s-alpha-1"),
                       "Attributed session must not appear in otherSessions")
    }

    // MARK: - Case 2: workspacesRoot match

    func testSessionUnderWorkspacesRootAttributesToProject() async throws {
        let configDir = try FixtureLite.tempDir("ext-case2-config")
        let projectPath = "/Users/x/Projects/beta"
        let wsRoot = "/Users/x/Workspaces/beta"
        let sessionCwd = wsRoot + "/ws-feature"

        try writeTranscript(configDir: configDir, cwd: sessionCwd, sessionId: "s-beta-1")

        let state = makeState()
        var project = ProjectConfig(name: "beta", path: projectPath)
        project.workspacesRoot = wsRoot
        state.config.projects = [project]
        state.config.accounts = [AccountConfig(name: "default", configDir: configDir.path)]

        await state.refreshSessionIndex()

        let bucket = state.externalSessionsByProject[project.id] ?? []
        XCTAssertEqual(bucket.map(\.id), ["s-beta-1"],
                       "Session under workspacesRoot must attribute to that project")
        XCTAssertFalse(state.otherSessions.map(\.id).contains("s-beta-1"),
                       "Attributed session must not appear in otherSessions")
    }

    // MARK: - Case 3: Unmatched cwd → otherSessions

    func testSessionWithNoCwdMatchLandsInOtherSessions() async throws {
        let configDir = try FixtureLite.tempDir("ext-case3-config")
        let sessionCwd = "/Users/x/random-project/work"

        try writeTranscript(configDir: configDir, cwd: sessionCwd, sessionId: "s-orphan-1")

        let state = makeState()
        // A project that does NOT match the session cwd.
        state.config.projects = [ProjectConfig(name: "unrelated", path: "/Users/x/Other")]
        state.config.accounts = [AccountConfig(name: "default", configDir: configDir.path)]

        await state.refreshSessionIndex()

        XCTAssertTrue(state.otherSessions.map(\.id).contains("s-orphan-1"),
                      "Session with no matching project must appear in otherSessions")
        // Must not be attributed to the unrelated project.
        for bucket in state.externalSessionsByProject.values {
            XCTAssertFalse(bucket.map(\.id).contains("s-orphan-1"),
                           "Unmatched session must not land in any externalSessionsByProject bucket")
        }
    }

    // MARK: - Case 4: Recency cap — old transcripts excluded

    func testOldTranscriptAppearsInNeitherBucket() async throws {
        let configDir = try FixtureLite.tempDir("ext-case4-config")
        let projectPath = "/Users/x/Projects/gamma"
        let sessionCwd = projectPath + "/old-work"

        let fileURL = try writeTranscript(configDir: configDir, cwd: sessionCwd, sessionId: "s-old-1")

        // Back-date the file to 120 days ago (beyond 90-day cap).
        let oldDate = Date(timeIntervalSinceNow: -120 * 86400)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: fileURL.path)

        let state = makeState()
        state.config.projects = [ProjectConfig(name: "gamma", path: projectPath)]
        state.config.accounts = [AccountConfig(name: "default", configDir: configDir.path)]

        await state.refreshSessionIndex()

        let allIds = (state.externalSessionsByProject.values.flatMap { $0 }.map(\.id))
            + state.otherSessions.map(\.id)
        XCTAssertFalse(allIds.contains("s-old-1"),
                       "Transcript older than recency cap must not appear in any bucket")
    }

    // MARK: - Case 5: Multi-project — sessions distribute to correct buckets

    func testMultipleSessionsDistributeToCorrectProjectBuckets() async throws {
        let configDir = try FixtureLite.tempDir("ext-case5-config")
        let pathA = "/Users/x/Projects/proj-a"
        let pathB = "/Users/x/Projects/proj-b"

        try writeTranscript(configDir: configDir, cwd: pathA + "/work", sessionId: "s-a-1", title: "A work")
        try writeTranscript(configDir: configDir, cwd: pathA + "/feat", sessionId: "s-a-2", title: "A feat")
        try writeTranscript(configDir: configDir, cwd: pathB + "/work", sessionId: "s-b-1", title: "B work")
        try writeTranscript(configDir: configDir, cwd: "/other/random", sessionId: "s-none", title: "No project")

        let state = makeState()
        let projA = ProjectConfig(name: "proj-a", path: pathA)
        let projB = ProjectConfig(name: "proj-b", path: pathB)
        state.config.projects = [projA, projB]
        state.config.accounts = [AccountConfig(name: "default", configDir: configDir.path)]

        await state.refreshSessionIndex()

        let bucketA = Set((state.externalSessionsByProject[projA.id] ?? []).map(\.id))
        let bucketB = Set((state.externalSessionsByProject[projB.id] ?? []).map(\.id))
        let others  = Set(state.otherSessions.map(\.id))

        XCTAssertEqual(bucketA, ["s-a-1", "s-a-2"], "Both A sessions must land in projA bucket")
        XCTAssertEqual(bucketB, ["s-b-1"],           "B session must land in projB bucket")
        XCTAssertEqual(others,  ["s-none"],           "Unmatched session must land in otherSessions")

        // Cross-check: no session appears in the wrong bucket.
        XCTAssertTrue(bucketA.isDisjoint(with: bucketB), "Project A and B buckets must not overlap")
        XCTAssertTrue(bucketA.isDisjoint(with: others),  "Attributed sessions must not leak to otherSessions")
        XCTAssertTrue(bucketB.isDisjoint(with: others),  "Attributed sessions must not leak to otherSessions")
    }
}
