import XCTest
@testable import GroveCore

/// The pipe drain, exercised directly.
///
/// `ProcessRunnerTests` drives real children, which is the right level for "does the
/// drain stay bounded" — but it cannot reach the one state that matters here: a reader
/// task that has not been SCHEDULED by the time the 2 s grace expires. Both readers are
/// `Task.detached` on the cooperative pool and each blocks a pool thread for the child's
/// whole life, so a wide fan-out of long-lived children (`WorkspaceService` starts an
/// unbounded group of 300 s hook processes) can starve one. The abandon check sits at the
/// TOP of the loop, before the first `poll`, so such a reader used to return an empty
/// `Data` for a child whose output had been sitting in the kernel pipe buffer since long
/// before it exited — and the caller saw exit 0 with no stdout, indistinguishable from a
/// command that printed nothing. The old `readDataToEndOfFile` was late in that
/// situation; it was never empty.
final class ProcessRunnerDrainTests: XCTestCase {
    /// The exact shape: the flag is already set when the drain starts, and the bytes are
    /// already in the pipe.
    func testADrainAbandonedBeforeItsFirstPollStillRecoversBufferedBytes() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("done: 42 workspaces\n".utf8))
        try pipe.fileHandleForWriting.close()

        let abandon = AbandonFlag()
        abandon.set()
        let data = drainPipe(pipe.fileHandleForReading, stream: "stdout",
                             command: "claude doctor", abandon: abandon)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "done: 42 workspaces\n",
                       "an abandoned drain must return the bytes already in the pipe, not nothing")
    }

    /// The sweep is a loop, not one lucky read: everything the writer left behind comes
    /// back, in order, however many reads that takes. (The payload stays inside the
    /// 64 KB pipe buffer on purpose — a writer still blocked on a full pipe when the
    /// drain closes the read end takes SIGPIPE, which is the writer's problem to have,
    /// not this test's to provoke.)
    func testTheFinalSweepReturnsEverythingThatWasBuffered() throws {
        let pipe = Pipe()
        let payload = Data(repeating: UInt8(ascii: "x"), count: 60_000)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()

        let abandon = AbandonFlag()
        abandon.set()
        let data = drainPipe(pipe.fileHandleForReading, stream: "stdout",
                             command: "big", abandon: abandon)
        XCTAssertEqual(data, payload, "a short read here is silent truncation reported as exit 0")
    }

    /// And it must not change the happy path: a drain that reaches EOF on its own still
    /// returns everything, once.
    func testAnUnabandonedDrainIsUnchanged() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("hello\n".utf8))
        try pipe.fileHandleForWriting.close()

        let data = drainPipe(pipe.fileHandleForReading, stream: "stdout",
                             command: "echo hello", abandon: AbandonFlag())
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello\n")
    }
}
