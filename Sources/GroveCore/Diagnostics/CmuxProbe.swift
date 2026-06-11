import Dispatch
import Foundation

/// Hidden diagnostic mode: `Grove --cmux-probe <outFile>`.
///
/// Runs the EXACT production cmux call path — `CmuxService()` default init,
/// from a @MainActor task like every AppState action — but WITHOUT the `try?`
/// error swallowing the production code does, and writes a step-by-step report
/// (environment, executable resolution, per-step exit code/stdout/stderr/error)
/// to `outFile`, then exits: 0 when every step passed, 1 otherwise.
///
/// To capture the true GUI context (LaunchServices launch: launchd ancestry —
/// which cmux's socket access control keys on — no TTY, cwd "/"), run it
/// through `open` against the built bundle:
///
///     open -nW dist/Grove.app --args --cmux-probe /tmp/cmux-probe.txt
///
/// (`-n` forces a new instance when Grove is already running.) Documented in
/// README "Troubleshooting". The probe creates ONE cmux workspace at a time
/// and closes it (plus any leaked "grove-probe"-titled ones from earlier
/// runs), and exercises BOTH backends: the unix-socket CLI and the
/// AppleScript fallback (see CmuxAppleScript). The first AppleScript call
/// can block on the macOS automation consent dialog — answer it on screen.
public enum CmuxProbe {

    /// Pure: the value following "--cmux-probe", nil when the flag is absent or last.
    public static func parseOutFile(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--cmux-probe"),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    /// True (and never actually returns: exit() inside) when "--cmux-probe
    /// <file>" is present; false when absent so main.swift starts the real app.
    /// The probe body runs in a @MainActor task (the production call path is
    /// @MainActor AppState) serviced by dispatchMain().
    public static func runIfRequested() -> Bool {
        guard let outFile = parseOutFile(from: CommandLine.arguments) else { return false }
        Task { @MainActor in
            let (report, ok) = await run()
            try? report.write(toFile: outFile, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data(report.utf8))
            exit(ok ? 0 : 1)
        }
        dispatchMain()
    }

    // MARK: - Probe body

    @MainActor
    static func run() async -> (report: String, ok: Bool) {
        var out: [String] = []
        var allOK = true
        let info = ProcessInfo.processInfo
        let fm = FileManager.default

        out.append("grove cmux probe — \(Date()) — grove \(GroveVersion.current)")
        out.append("pid \(info.processIdentifier)  cwd \(fm.currentDirectoryPath)")
        out.append("arguments: \(CommandLine.arguments.joined(separator: " "))")
        out.append("tty: stdin=\(isatty(0)) stdout=\(isatty(1)) stderr=\(isatty(2))")
        out.append("")

        out.append("== environment (\(info.environment.count) vars) ==")
        for key in info.environment.keys.sorted() {
            out.append("\(key)=\(info.environment[key] ?? "")")
        }
        out.append("")

        // Production default init: this is exactly what AppState.cmux() builds.
        let service = CmuxService()
        let runner = ProcessRunner()
        out.append("== executable resolution ==")
        out.append("PATH=\(info.environment["PATH"] ?? "<unset>")")
        out.append("resolved executable: \(service.executable)")
        out.append("fallback \(CmuxService.fallbackPath) isExecutable: \(fm.isExecutableFile(atPath: CmuxService.fallbackPath))")
        out.append("")

        func record(_ name: String, started: Date, _ detail: String) {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            out.append("[\(name)] (\(ms)ms) \(detail)")
        }
        func fail(_ name: String, started: Date, _ error: Error) {
            allOK = false
            record(name, started: started, "FAILED: \(error)")
        }

        // Step 1: raw ping — same executable/args as production ping(), but
        // exit code, stdout and stderr captured verbatim (ping() swallows them).
        var t = Date()
        do {
            let r = try await runner.run(service.executable, ["ping"], cwd: nil, env: nil, timeout: 10)
            record("raw ping", started: t,
                   "exit=\(r.exitCode) stdout=\(String(reflecting: r.stdout)) stderr=\(String(reflecting: r.stderr))")
            if r.exitCode != 0 { allOK = false }
        } catch {
            fail("raw ping", started: t, error)
        }

        // Step 2: production ping(). With the AppleScript fallback in place,
        // a socket denial now yields ping=true (cmux reachable via AppleScript).
        t = Date()
        let pong = await service.ping()
        record("ping()", started: t, (pong ? "OK" : "FAILED: returned false")
               + " — active backend: \(Self.backendName())")
        if !pong { allOK = false }

        // Step 3: production ensureRunning().
        t = Date()
        do {
            try await service.ensureRunning()
            record("ensureRunning()", started: t, "OK — active backend: \(Self.backendName())")
        } catch {
            fail("ensureRunning()", started: t, error)
        }

        // Step 4: production listWorkspaces() (socket first, AppleScript on denial).
        t = Date()
        do {
            let list = try await service.listWorkspaces()
            record("listWorkspaces()", started: t,
                   "OK via \(Self.backendName()): \(list.count) workspaces: "
                   + list.map(\.title).joined(separator: ", "))
        } catch {
            fail("listWorkspaces()", started: t, error)
        }

        // Steps 5+6: production create + close. The created workspace is found
        // by diffing ids (the AppleScript backend cannot name tabs, so the
        // "grove-probe" title only exists on the socket path).
        t = Date()
        do {
            let before = try await service.listWorkspaces()
            try await service.newWorkspace(name: "grove-probe", cwd: NSTemporaryDirectory(),
                                           command: nil, focus: false)
            record("newWorkspace(grove-probe)", started: t,
                   "OK via \(Self.backendName())")
            t = Date()
            let after = try await service.listWorkspaces()
            let beforeIds = Set(before.map(\.id))
            // Leaked probes from interrupted earlier runs are titled
            // "grove-probe" (socket path); include them in the cleanup.
            let toClose = after.filter { !beforeIds.contains($0.id) || $0.title == "grove-probe" }
            if toClose.isEmpty {
                allOK = false
                record("closeWorkspace", started: t, "FAILED: created workspace not found in list diff")
            }
            for ws in toClose {
                try await service.closeWorkspace(ws.id)
                record("closeWorkspace(\(ws.id))", started: t, "OK")
            }
        } catch {
            fail("newWorkspace/closeWorkspace", started: t, error)
        }

        // AppleScript backend, exercised DIRECTLY so the probe proves both
        // legs regardless of which one the service is currently routed to.
        // The first Apple Event from a freshly (re)signed Grove triggers the
        // macOS automation consent dialog and blocks until it is answered.
        out.append("")
        out.append("== AppleScript backend (direct) ==")
        let scripting = CmuxAppleScript()
        out.append("[AS running] cmux app running: \(scripting.isAppRunning())")

        // Transport micro-benchmarks. The backend transport is an osascript
        // child (in-process NSAppleScript stalls non-deterministically from
        // GUI Grove, see CmuxAppleScript); the raw-osascript lines below
        // cross-check the child transport without the backend's plumbing.
        let versionScript = "tell application id \"\(CmuxService.bundleID)\" to get version"
        t = Date()
        do {
            let v = try await scripting.runScript(versionScript)
            record("AS micro get-version (backend transport)", started: t, "OK: \(v)")
        } catch {
            fail("AS micro get-version (backend transport)", started: t, error)
        }
        t = Date()
        do {
            let r = try await runner.run("/usr/bin/osascript", ["-e", versionScript],
                                         cwd: nil, env: nil, timeout: 150)
            record("AS micro get-version (osascript child)", started: t,
                   "exit=\(r.exitCode) stdout=\(String(reflecting: r.stdout)) stderr=\(String(reflecting: r.stderr.prefix(200)))")
        } catch {
            fail("AS micro get-version (osascript child)", started: t, error)
        }
        t = Date()
        do {
            let r = try await runner.run("/usr/bin/osascript", ["-e", CmuxAppleScript.listScriptSource],
                                         cwd: nil, env: nil, timeout: 150)
            let rows = r.stdout.components(separatedBy: CmuxAppleScript.rowSeparator)
                .filter { !$0.isEmpty }
            record("AS full list (osascript child)", started: t,
                   "exit=\(r.exitCode) rows=\(rows.count) stderr=\(String(reflecting: r.stderr.prefix(200)))")
        } catch {
            fail("AS full list (osascript child)", started: t, error)
        }

        var asListOK = false
        t = Date()
        do {
            let list = try await scripting.listWorkspaces()
            asListOK = !list.isEmpty
            record("AS list", started: t, "OK: \(list.count) workspaces; first: "
                   + list.prefix(3).map { "\($0.title) @ \($0.currentDirectory)" }
                       .joined(separator: " | "))
            if list.isEmpty { allOK = false }
        } catch {
            fail("AS list", started: t, error)
        }
        // Direct AS create+close only when the service leg above ran on the
        // socket (otherwise the AppleScript leg was already exercised, and a
        // second probe tab would disturb the user's cmux for no extra signal).
        if asListOK && !CmuxBackendState.shared.useAppleScript {
            // Per-script timing of the create+close leg (the trace hook lines
            // are appended to the report after the step).
            let traceBox = TraceBox()
            CmuxAppleScript.trace = { traceBox.append($0) }
            defer {
                CmuxAppleScript.trace = nil
                out.append("-- AS script trace --")
                out.append(contentsOf: traceBox.lines())
            }
            t = Date()
            do {
                let before = try await scripting.listWorkspaces()
                try await scripting.newWorkspace(cwd: NSTemporaryDirectory(), command: nil, focus: false)
                let after = try await scripting.listWorkspaces()
                let beforeIds = Set(before.map(\.id))
                let added = after.filter { !beforeIds.contains($0.id) }
                for ws in added {
                    try await scripting.closeWorkspace(
                        tabId: CmuxAppleScript.tabId(fromNamespaced: ws.id) ?? ws.id)
                }
                record("AS create+close", started: t,
                       added.isEmpty ? "FAILED: no new tab in list diff" : "OK (\(added.map(\.id).joined(separator: ", ")))")
                if added.isEmpty { allOK = false }
            } catch {
                fail("AS create+close", started: t, error)
            }
        } else if asListOK {
            out.append("[AS create+close] covered by the service steps above (fallback active)")
        }

        // Extra context experiments (do not affect allOK except where noted):
        out.append("")
        out.append("== experiments ==")

        // E1: CLI runs at all (no socket needed for --version).
        t = Date()
        do {
            let r = try await runner.run(service.executable, ["--version"], cwd: nil, env: nil, timeout: 10)
            record("E1 cmux --version", started: t, "exit=\(r.exitCode) stdout=\(String(reflecting: r.stdout.prefix(120)))")
        } catch { record("E1 cmux --version", started: t, "FAILED: \(error)") }

        // E2: identify — server identity and caller context (needs socket).
        t = Date()
        do {
            let r = try await runner.run(service.executable, ["identify"], cwd: nil, env: nil, timeout: 10)
            record("E2 cmux identify", started: t,
                   "exit=\(r.exitCode) stdout=\(String(reflecting: r.stdout)) stderr=\(String(reflecting: r.stderr))")
        } catch { record("E2 cmux identify", started: t, "FAILED: \(error)") }

        // E3: explicit --socket with the resolved socket path.
        let socketPath = CmuxService.controlSocketPath()
        t = Date()
        do {
            let r = try await runner.run(service.executable, ["--socket", socketPath, "ping"], cwd: nil, env: nil, timeout: 10)
            record("E3 ping --socket \(socketPath)", started: t,
                   "exit=\(r.exitCode) stdout=\(String(reflecting: r.stdout)) stderr=\(String(reflecting: r.stderr))")
        } catch { record("E3 ping --socket", started: t, "FAILED: \(error)") }

        // E4: minimal env (HOME only), absolute fallback binary, bypassing
        // ProcessRunner's env inheritance — the configuration the orchestrator
        // verified works from a terminal.
        t = Date()
        out.append(minimalEnvPing())
        record("E4 done", started: t, "")

        // E5: production denial probe — raw read-only connect from THIS
        // process. cmux's server rejects unauthorized peers by writing one
        // "ERROR: ..." line and hanging up; authorized peers see silence (nil).
        let greeting = CmuxService.readSocketGreeting(path: socketPath)
        out.append("[E5 socket greeting] path=\(socketPath) -> "
                   + (greeting.map { String(reflecting: $0) } ?? "nil (silent: authorized, or socket absent)"))

        // E6: socket password resolution from cmux's own config.
        let password = CmuxService.socketPassword(configFile: nil)
        out.append("[E6 socket password] automation.socketPassword "
                   + (password == nil ? "not configured" : "configured (forwarded as CMUX_SOCKET_PASSWORD)"))

        out.append("")
        out.append("final active backend: \(Self.backendName())")
        out.append(allOK ? "RESULT: ALL STEPS OK" : "RESULT: FAILURES (see above)")
        return (out.joined(separator: "\n") + "\n", allOK)
    }

    /// The backend the production CmuxService is currently routed to.
    static func backendName() -> String {
        CmuxBackendState.shared.useAppleScript ? "applescript (socket denied -> fallback)" : "socket"
    }

    /// Lock-guarded line collector for CmuxAppleScript.trace.
    private final class TraceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [String] = []
        func append(_ line: String) { lock.lock(); collected.append(line); lock.unlock() }
        func lines() -> [String] { lock.lock(); defer { lock.unlock() }; return collected }
    }

    /// Spawns the fallback cmux binary with env = [HOME] only (like `env -i
    /// HOME=$HOME cmux ping`), synchronously, raw Process (not ProcessRunner).
    static func minimalEnvPing() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CmuxService.fallbackPath)
        p.arguments = ["ping"]
        p.environment = ["HOME": NSHomeDirectory()]
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return "[E4 minimal-env ping] spawn failed: \(error)"
        }
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return "[E4 minimal-env ping] exit=\(p.terminationStatus) stdout=\(String(reflecting: stdout)) stderr=\(String(reflecting: stderr))"
    }

}
