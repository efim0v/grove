import XCTest
@testable import GroveAppKit
@testable import GroveCore

@MainActor
final class AppStateTranscriptMirrorTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var configURL: URL!

    override func setUp() async throws {
        root = try FixtureLite.tempDir("appstate-mirror")
        configURL = root.appendingPathComponent("config.json")
    }

    // MARK: - helpers

    private func makeState() -> AppState {
        let state = AppState(configStore: ConfigStore(url: configURL))
        // Fail-safe: always point canonical away from the real ~/.claude.
        state.canonicalDirOverride = root.appendingPathComponent("canonical-default").path
        return state
    }

    // MARK: - tests

    func testReconcileTranscriptsRestoresAMissingTranscript() async throws {
        let canonical = root.appendingPathComponent("canonical")
        try fm.createDirectory(at: canonical.appendingPathComponent("projects/-p"),
                               withIntermediateDirectories: true)
        let live = canonical.appendingPathComponent("projects/-p/iiii.jsonl")
        try "hi\n".write(to: live, atomically: true, encoding: .utf8)

        let state = makeState()
        state.canonicalDirOverride = canonical.path
        state.config = GroveConfig(
            version: 1, workspacesRootTemplate: "~/w", projects: [],
            accounts: [AccountConfig(name: "default", configDir: canonical.path)])

        await state.reconcileTranscripts()      // links live → mirror
        try fm.removeItem(at: live)             // out-of-band delete
        await state.reconcileTranscripts()      // restores from mirror
        XCTAssertTrue(fm.fileExists(atPath: live.path),
                      "AppState should restore via the mirror")
    }

    func testDisabledIsANoOp() async throws {
        let canonical = root.appendingPathComponent("canonical-off")
        try fm.createDirectory(at: canonical.appendingPathComponent("projects/-p"),
                               withIntermediateDirectories: true)
        try "hi\n".write(to: canonical.appendingPathComponent("projects/-p/jjjj.jsonl"),
                         atomically: true, encoding: .utf8)

        let state = makeState()
        state.canonicalDirOverride = canonical.path
        var cfg = GroveConfig(
            version: 1, workspacesRootTemplate: "~/w", projects: [],
            accounts: [AccountConfig(name: "default", configDir: canonical.path)])
        cfg.transcriptMirror = TranscriptMirrorSettings(enabled: false)
        state.config = cfg

        await state.reconcileTranscripts()
        XCTAssertFalse(
            fm.fileExists(atPath: TranscriptMirror.mirrorRoot(canonicalDir: canonical.path)),
            "disabled → no mirror dir created")
    }
}
