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
}
