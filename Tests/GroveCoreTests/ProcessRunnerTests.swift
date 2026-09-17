import XCTest
import GroveCore

final class ProcessRunnerTests: XCTestCase {
    private let runner = ProcessRunner()

    func testEchoResolvedViaEnv() async throws {
        let result = try await runner.run("echo", ["hello"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testNonzeroExitCaptured() async throws {
        let result = try await runner.run("zsh", ["-c", "exit 7"])
        XCTAssertEqual(result.exitCode, 7)
    }

    func testStderrCaptured() async throws {
        let result = try await runner.run("zsh", ["-c", "echo oops 1>&2"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "oops\n")
        XCTAssertEqual(result.stdout, "")
    }

    func testCwdHonored() async throws {
        let dir = try Fixture.tempDir("runner-cwd")
        let result = try await runner.run("pwd", [], cwd: dir.path)
        let printed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // /var and /tmp are symlinks on macOS; compare physical paths.
        XCTAssertEqual(
            URL(fileURLWithPath: printed).resolvingSymlinksInPath().path,
            dir.resolvingSymlinksInPath().path
        )
    }

    func testEnvMergedOverParentEnvironment() async throws {
        let result = try await runner.run(
            "zsh", ["-c", "printf '%s' \"$GROVE_TEST_VAR\""],
            env: ["GROVE_TEST_VAR": "42"]
        )
        XCTAssertEqual(result.stdout, "42")
    }

    func testTimeoutThrowsGroveErrorTimeout() async throws {
        let start = Date()
        do {
            _ = try await runner.run("zsh", ["-c", "sleep 5"], timeout: 0.5)
            XCTFail("expected GroveError.timeout")
        } catch let error as GroveError {
            guard case .timeout(let command) = error else {
                return XCTFail("expected .timeout, got \(error)")
            }
            XCTAssertTrue(command.contains("sleep 5"))
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 4.0,
            "watchdog must fire well before sleep 5 finishes"
        )
    }

    /// `sleep 6 &` is a grandchild: it inherits the shell's fd 1 and fd 2, which are
    /// the pipes' write ends, and keeps them open for the full six seconds even
    /// though the child shell exits immediately. `readDataToEndOfFile` returns only
    /// when the LAST writer closes, so the old drain held the caller for those 6 s.
    /// The drain must be bounded: return what the child wrote, and stop reading.
    func testReturnsPromptlyWhenAGrandchildKeepsStdoutOpen() async throws {
        let start = Date()
        let result = try await runner.run(
            "/bin/sh", ["-c", "(sleep 6 &) ; echo out; echo err 1>&2; exit 0"],
            timeout: 10
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed, 4.0,
            "a grandchild holding the write end must not hold the caller (took \(elapsed) s)"
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("out"), "stdout was \(result.stdout.debugDescription)")
        XCTAssertTrue(result.stderr.contains("err"), "stderr was \(result.stderr.debugDescription)")
    }

    /// Same grandchild, but the child itself outlives the timeout: the watchdog
    /// still wins, and the bounded drain that follows it does not swallow the throw
    /// or stretch the call out to the grandchild's lifetime.
    func testTimeoutStillThrowsAndDoesNotHangOnDrain() async throws {
        let start = Date()
        do {
            _ = try await runner.run("/bin/sh", ["-c", "(sleep 6 &); sleep 6"], timeout: 1)
            XCTFail("expected GroveError.timeout")
        } catch let error as GroveError {
            guard case .timeout(let command) = error else {
                return XCTFail("expected .timeout, got \(error)")
            }
            XCTAssertTrue(command.contains("sleep 6"))
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed, 4.0,
            "the drain after a timeout must stay bounded (took \(elapsed) s)"
        )
    }

    /// An abandoned drain stops at an arbitrary byte offset, which can cut a
    /// multi-byte UTF-8 sequence in half. `String(data:encoding:.utf8)` answers nil
    /// for a stream like that, and the `?? ""` behind it would throw the WHOLE
    /// stream away — silent total data loss reported as a clean exit 0. The lossy
    /// decoder costs one replacement character instead. 0xC3 followed by `a` is
    /// exactly such a half sequence.
    func testInvalidUTF8KeepsTheRestOfTheStream() async throws {
        let result = try await runner.run(
            "/bin/sh", ["-c", "printf 'before'; printf '\\303'; printf 'after'; printf 'bad' 1>&2; printf '\\303' 1>&2"]
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.hasPrefix("before"), "stdout was \(result.stdout.debugDescription)")
        XCTAssertTrue(result.stdout.hasSuffix("after"), "stdout was \(result.stdout.debugDescription)")
        XCTAssertTrue(result.stderr.hasPrefix("bad"), "stderr was \(result.stderr.debugDescription)")
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        // 200KB >> 64KB pipe buffer; hangs forever if pipes are not drained concurrently.
        let result = try await runner.run("zsh", ["-c", "yes | head -c 200000"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 200_000)
    }

    func testRunOKThrowsProcessFailed() async throws {
        do {
            _ = try await runner.runOK("zsh", ["-c", "echo boom 1>&2; exit 3"])
            XCTFail("expected GroveError.processFailed")
        } catch let error as GroveError {
            guard case .processFailed(_, let exitCode, let stderr) = error else {
                return XCTFail("expected .processFailed, got \(error)")
            }
            XCTAssertEqual(exitCode, 3)
            XCTAssertTrue(stderr.contains("boom"))
        }
    }

    func testRunOKPassesThroughOnSuccess() async throws {
        let result = try await runner.runOK("echo", ["ok"])
        XCTAssertEqual(result.stdout, "ok\n")
    }

    /// Stress: many concurrent runs in a TaskGroup, as scan() does. Guards the
    /// pipe-drain/termination plumbing under release-mode concurrency. (The
    /// 2026-06 release-only scan bug turned out NOT to be ProcessRunner — see
    /// ScanWorktreeCollectionTests — but this coverage is worth keeping.)
    func testManyConcurrentRunsReturnFullOutput() async throws {
        let runner = self.runner
        try await withThrowingTaskGroup(of: (Int, ProcessResult).self) { group in
            for i in 0..<64 {
                group.addTask {
                    (i, try await runner.run("echo", ["hello-\(i)"]))
                }
            }
            for try await (i, result) in group {
                XCTAssertEqual(result.exitCode, 0)
                XCTAssertEqual(result.stdout, "hello-\(i)\n", "lost stdout for run \(i)")
            }
        }
    }
}
