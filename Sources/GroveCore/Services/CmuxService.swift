import Foundation

public struct CmuxWorkspace: Sendable, Equatable {
    public let id: String
    public let title: String
    public let currentDirectory: String

    public init(id: String, title: String, currentDirectory: String) {
        self.id = id
        self.title = title
        self.currentDirectory = currentDirectory
    }
}

/// Process-wide memory of which cmux backend is in use. Set to AppleScript
/// when the control socket denies Grove; cleared whenever the socket answers
/// again (after the user restarts cmux in "automation" mode the socket
/// silently resumes — listWorkspaces re-probes it on every call). Shared
/// because AppState constructs a fresh CmuxService per interaction.
final class CmuxBackendState: @unchecked Sendable {
    static let shared = CmuxBackendState()
    private let lock = NSLock()
    private var fallback = false

    var useAppleScript: Bool {
        get { lock.lock(); defer { lock.unlock() }; return fallback }
        set { lock.lock(); fallback = newValue; lock.unlock() }
    }
}

public struct CmuxService: Sendable {
    private let runner: any CommandRunning
    private let cmuxPath: String?
    /// cmux's own config file used to resolve automation.socketPassword;
    /// nil = the real ~/.config/cmux locations. Test seam.
    private let configFile: String?
    /// Raw-socket denial probe (see readSocketGreeting). Test seam.
    private let socketGreeting: @Sendable (String) -> String?
    // BACKEND SEAM. The unix-socket CLI is the primary backend; `scripting`
    // (AppleScript, see CmuxAppleScript) is the fallback used while
    // `backend.useAppleScript` is set after a socket access denial.
    // NOTE for the future: this seam is where other terminal providers
    // (Terminal.app, iTerm2, Ghostty) plug in later — they would implement
    // CmuxScripting-like backends selected by configuration instead of by
    // denial fallback.
    private let scripting: any CmuxScripting
    private let backend: CmuxBackendState

    /// Socket refusal carried internally so each public operation can flip to
    /// the AppleScript backend; never escapes the public API.
    private struct SocketDenied: Error { let line: String }

    static let fallbackPath = "/Applications/cmux.app/Contents/Resources/bin/cmux"
    static let bundleID = "com.cmuxterm.app"

    public init(runner: any CommandRunning = ProcessRunner(), cmuxPath: String? = nil) {
        self.init(runner: runner, cmuxPath: cmuxPath, configFile: nil,
                  socketGreeting: { Self.readSocketGreeting(path: $0) },
                  scripting: CmuxAppleScript(), backend: .shared)
    }

    /// Full-seam init for tests: configFile feeds password resolution,
    /// socketGreeting replaces the raw-socket denial probe, scripting/backend
    /// replace the AppleScript fallback (tests MUST pass a fresh
    /// CmuxBackendState, never .shared, to stay hermetic).
    init(runner: any CommandRunning, cmuxPath: String?, configFile: String?,
         socketGreeting: @escaping @Sendable (String) -> String?,
         scripting: any CmuxScripting, backend: CmuxBackendState) {
        self.runner = runner
        self.cmuxPath = cmuxPath
        self.configFile = configFile
        self.socketGreeting = socketGreeting
        self.scripting = scripting
        self.backend = backend
    }

    /// Explicit path wins; otherwise "cmux" when a PATH lookup finds it,
    /// otherwise the app-bundle fallback binary, otherwise bare "cmux"
    /// (ProcessRunner resolves bare names via /usr/bin/env).
    var executable: String {
        if let cmuxPath { return cmuxPath }
        let fm = FileManager.default
        let pathVar = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathVar.split(separator: ":") where !dir.isEmpty {
            if fm.isExecutableFile(atPath: "\(dir)/cmux") { return "cmux" }
        }
        if fm.isExecutableFile(atPath: Self.fallbackPath) { return Self.fallbackPath }
        return "cmux"
    }

    public func ping() async -> Bool {
        let result = await pingResult()
        if result.ok {
            backend.useAppleScript = false
            return true
        }
        // Denied (or already in fallback mode): cmux is reachable when the
        // AppleScript backend can see the running app.
        if result.denied != nil || backend.useAppleScript {
            if scripting.isAppRunning() {
                backend.useAppleScript = true
                return true
            }
        }
        return false
    }

    /// ping with the failure detail preserved (ping() collapses it to a Bool).
    /// `denied` carries the server's refusal line when the socket actively
    /// rejected us (the trigger for the AppleScript fallback).
    func pingResult() async -> (ok: Bool, detail: String?, denied: String?) {
        do {
            let result = try await runner.run(executable, ["ping"], cwd: nil, env: passwordEnv(), timeout: 10)
            if result.exitCode == 0
                && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "PONG" {
                return (true, nil, nil)
            }
            let firstErrorLine = result.stderr
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").first.map(String.init) ?? ""
            return (false, "ping exit=\(result.exitCode)"
                        + (firstErrorLine.isEmpty ? "" : ": \(firstErrorLine)"),
                    denialEvidence(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr))
        } catch {
            return (false, "ping failed: \(error)", nil)
        }
    }

    public func ensureRunning() async throws {
        var last = await pingResult()
        if last.ok {
            backend.useAppleScript = false
            return
        }
        // cmux is RUNNING but refusing us (socketControlMode "cmuxOnly"): the
        // refusal itself proves the app is alive, so the AppleScript backend
        // can serve every operation — switch over instead of failing.
        if last.denied != nil {
            backend.useAppleScript = true
            return
        }
        if backend.useAppleScript && scripting.isAppRunning() { return }
        _ = try? await runner.run("/usr/bin/open", ["-b", Self.bundleID], cwd: nil, env: nil, timeout: 10)
        let deadline = Date().addingTimeInterval(10)
        while true {
            last = await pingResult()
            if last.ok {
                backend.useAppleScript = false
                return
            }
            // A cmux we just launched comes up in "cmuxOnly" mode too.
            if last.denied != nil {
                backend.useAppleScript = true
                return
            }
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        // App is up but its socket never answered: AppleScript can still drive it.
        if scripting.isAppRunning() {
            backend.useAppleScript = true
            return
        }
        let detail = last.detail.map { " (last \($0))" } ?? ""
        throw GroveError.cmuxUnavailable(
            "cmux did not answer ping within 10s after launching \(Self.bundleID)\(detail)")
    }

    /// Non-nil when a failed CLI call means the server DENIED us: either the
    /// denial text surfaced directly, or the CLI's opaque "Broken pipe" hangup
    /// is confirmed as a denial by reading the socket's greeting.
    private func denialEvidence(exitCode: Int32, stdout: String, stderr: String) -> String? {
        guard exitCode != 0 else { return nil }
        let combined = stderr + "\n" + stdout
        if combined.contains("Access denied") {
            return combined.split(separator: "\n")
                .first(where: { $0.contains("Access denied") })
                .map(String.init)
        }
        if combined.contains("Failed to write to socket") || combined.contains("Broken pipe") {
            return socketDenial()
        }
        return nil
    }

    /// Runs a cmux CLI command. A denial (see denialEvidence) is thrown as the
    /// internal SocketDenied so callers can fall back to AppleScript; other
    /// failures stay GroveError.processFailed.
    private func runCmux(_ args: [String]) async throws -> ProcessResult {
        let result = try await runner.run(executable, args, cwd: nil, env: passwordEnv(), timeout: 10)
        if result.exitCode == 0 { return result }
        if let line = denialEvidence(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr) {
            throw SocketDenied(line: line)
        }
        throw GroveError.processFailed(
            command: ([executable] + args).joined(separator: " "),
            exitCode: result.exitCode,
            stderr: result.stderr)
    }

    /// Switches to the AppleScript backend after a socket denial; throws the
    /// actionable denial message when the app is not even running (denial with
    /// no app should not happen, but a race with cmux quitting can produce it).
    private func appleScriptFallback(_ denial: SocketDenied) throws -> any CmuxScripting {
        backend.useAppleScript = true
        guard scripting.isAppRunning() else {
            throw GroveError.cmuxUnavailable(Self.denialMessage(denial.line))
        }
        return scripting
    }

    private struct WorkspaceDTO: Decodable {
        let id: String
        let title: String?
        let currentDirectory: String

        enum CodingKeys: String, CodingKey {
            case id, title
            case currentDirectory = "current_directory"
        }
    }

    /// Real cmux (>= 0.64) wraps the list in an envelope object:
    /// {"window_id": "...", "window_ref": "...", "workspaces": [...]}.
    private struct WorkspaceListEnvelope: Decodable {
        let workspaces: [WorkspaceDTO]
    }

    /// Always attempts the socket first, even in AppleScript-fallback mode:
    /// after the user restarts cmux with socketControlMode "automation" the
    /// socket starts accepting us again, and this is where Grove notices and
    /// silently switches back.
    public func listWorkspaces() async throws -> [CmuxWorkspace] {
        do {
            let result = try await runCmux(["rpc", "workspace.list", "{}"])
            let parsed = try Self.parseWorkspaceList(result.stdout)
            backend.useAppleScript = false
            return parsed
        } catch let denial as SocketDenied {
            return try await appleScriptFallback(denial).listWorkspaces()
        } catch {
            // Non-denial socket trouble while already in fallback mode: serve
            // from AppleScript rather than surfacing a socket error.
            if backend.useAppleScript, scripting.isAppRunning() {
                return try await scripting.listWorkspaces()
            }
            throw error
        }
    }

    static func parseWorkspaceList(_ stdout: String) throws -> [CmuxWorkspace] {
        let data = Data(stdout.utf8)
        let decoder = JSONDecoder()
        let dtos: [WorkspaceDTO]
        if let envelope = try? decoder.decode(WorkspaceListEnvelope.self, from: data) {
            dtos = envelope.workspaces
        } else {
            // Fallback for cmux versions that return(ed) a bare top-level array.
            do {
                dtos = try decoder.decode([WorkspaceDTO].self, from: data)
            } catch {
                throw GroveError.cmuxUnavailable("workspace.list returned unparseable JSON: \(error)")
            }
        }
        return dtos.map { CmuxWorkspace(id: $0.id, title: $0.title ?? "", currentDirectory: $0.currentDirectory) }
    }

    /// cmux constrains focus-stealing, so "--focus true" alone does not bring
    /// the app forward; an explicit `open -b` activation is required after it.
    private func activateApp() async throws {
        _ = try await runner.runOK("/usr/bin/open", ["-b", Self.bundleID], cwd: nil, env: nil, timeout: 10)
    }

    public func newWorkspace(name: String, cwd: String, command: String?, focus: Bool) async throws {
        if backend.useAppleScript, scripting.isAppRunning() {
            try await scripting.newWorkspace(cwd: cwd, command: command, focus: focus)
        } else {
            do {
                var args = ["new-workspace", "--name", name, "--cwd", cwd]
                if let command { args += ["--command", command] }
                args += ["--focus", focus ? "true" : "false"]
                _ = try await runCmux(args)
            } catch let denial as SocketDenied {
                try await appleScriptFallback(denial)
                    .newWorkspace(cwd: cwd, command: command, focus: focus)
            }
        }
        if focus { try await activateApp() }
    }

    public func selectWorkspace(_ idOrRef: String) async throws {
        // "as:" ids were minted by the AppleScript backend's list — they route
        // back to it even if the socket has resumed in the meantime.
        if let tabId = CmuxAppleScript.tabId(fromNamespaced: idOrRef) {
            try await scripting.selectWorkspace(tabId: tabId)
        } else if backend.useAppleScript, scripting.isAppRunning() {
            // Socket workspace ids ARE the AppleScript tab ids (verified
            // against cmux 0.64.4), so ids from claudeSessionWorkspaceMap or a
            // pre-fallback list keep working across the backend switch.
            try await scripting.selectWorkspace(tabId: idOrRef)
        } else {
            do {
                _ = try await runCmux(["select-workspace", "--workspace", idOrRef])
            } catch let denial as SocketDenied {
                try await appleScriptFallback(denial).selectWorkspace(tabId: idOrRef)
            }
        }
        try await activateApp()
    }

    public func closeWorkspace(_ idOrRef: String) async throws {
        if let tabId = CmuxAppleScript.tabId(fromNamespaced: idOrRef) {
            try await scripting.closeWorkspace(tabId: tabId)
        } else if backend.useAppleScript, scripting.isAppRunning() {
            try await scripting.closeWorkspace(tabId: idOrRef)
        } else {
            do {
                _ = try await runCmux(["close-workspace", "--workspace", idOrRef])
            } catch let denial as SocketDenied {
                try await appleScriptFallback(denial).closeWorkspace(tabId: idOrRef)
            }
        }
    }

    /// Claude session id -> cmux workspace id, from cmux's hook registry
    /// (~/.cmuxterm/claude-hook-sessions.json). Lets "go to session" target the
    /// exact cmux workspace hosting that session. Missing/corrupt file -> empty map.
    public func claudeSessionWorkspaceMap(hookFile: String? = nil) -> [String: String] {
        let path = expandTilde(hookFile ?? "~/.cmuxterm/claude-hook-sessions.json")
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        var map: [String: String] = [:]
        for (sessionId, value) in obj {
            if let dict = value as? [String: Any], let ws = dict["workspaceId"] as? String {
                map[sessionId] = ws
            }
        }
        return map
    }
}

// MARK: - Socket access control (cmux denies external clients by default)
//
// cmux's control socket enforces automation.socketControlMode (default
// "cmuxOnly"): the server only accepts clients whose process ancestry traces
// into the cmux app. Grove launched from Finder/Dock/`open` descends from
// launchd, so EVERY CLI call is rejected — the server writes one
// "ERROR: Access denied — only processes started inside cmux can connect"
// line and hangs up, which the CLI reports only as "Failed to write to socket
// (Broken pipe, errno 32)". The same commands work from any cmux-hosted
// terminal, which is what made this bug look context-dependent.
// Sanctioned ways in: socketControlMode "automation" (allow same-user external
// clients) or "password" + automation.socketPassword (Grove forwards it via
// CMUX_SOCKET_PASSWORD automatically, see passwordEnv()).
// Diagnostic: `Grove --cmux-probe <outFile>` (see CmuxProbe).
extension CmuxService {
    /// cmux control socket path, mirroring the CLI's resolution:
    /// CMUX_SOCKET_PATH, legacy CMUX_SOCKET, else the app-support default.
    static func controlSocketPath(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let path = env["CMUX_SOCKET_PATH"], !path.isEmpty { return path }
        if let path = env["CMUX_SOCKET"], !path.isEmpty { return path }
        return NSHomeDirectory() + "/Library/Application Support/cmux/cmux.sock"
    }

    /// Non-nil when the cmux server actively REFUSED our connection (it
    /// answers with an ERROR line and hangs up); nil when cmux is simply not
    /// running or accepts us.
    private func socketDenial() -> String? {
        guard let line = socketGreeting(Self.controlSocketPath()),
              line.hasPrefix("ERROR") else { return nil }
        return line
    }

    static func denialMessage(_ serverLine: String) -> String {
        serverLine
            + " — Grove runs outside cmux, and cmux's socket control mode"
            + " (automation.socketControlMode, default \"cmuxOnly\") blocks external"
            + " clients. In cmux: Settings > Automation > Socket control mode ->"
            + " \"Automation\" (allows clients from your user account), or set a"
            + " socket password there (Grove picks it up from ~/.config/cmux/cmux.json"
            + " automatically). cmux applies the mode when its CLI listener starts:"
            + " after changing it, run cmux's \"Restart CLI Listener\" palette command"
            + " or restart cmux."
    }

    /// Connects to the unix socket and reads for up to 1s WITHOUT writing.
    /// cmux rejects unauthorized peers by immediately writing one "ERROR: ..."
    /// line and closing; authorized connections stay silent (the server waits
    /// for a request), which lands in the read timeout -> nil. nil also when
    /// the socket is absent/refusing (cmux not running).
    static func readSocketGreeting(path: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let fits = withUnsafeMutableBytes(of: &addr.sun_path) { raw -> Bool in
            let bytes = Array(path.utf8)
            guard bytes.count < raw.count else { return false }
            raw.copyBytes(from: bytes)
            return true
        }
        guard fits else { return nil }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let got = read(fd, &buffer, buffer.count)
        guard got > 0 else { return nil }
        return String(decoding: buffer[0..<got], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// CMUX_SOCKET_PASSWORD sourced from cmux's own config
    /// (automation.socketPassword) so "password" socket-control mode works
    /// with zero Grove-side configuration. nil (inherit unchanged environment)
    /// when no password is configured.
    private func passwordEnv() -> [String: String]? {
        guard let password = Self.socketPassword(configFile: configFile) else { return nil }
        return ["CMUX_SOCKET_PASSWORD": password]
    }

    static func socketPassword(configFile: String?) -> String? {
        let candidates = configFile.map { [$0] } ?? [
            expandTilde("~/.config/cmux/cmux.json"),
            expandTilde("~/.config/cmux/settings.json"),
        ]
        for path in candidates {
            guard let data = FileManager.default.contents(atPath: path),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let automation = object["automation"] as? [String: Any],
                  let password = automation["socketPassword"] as? String,
                  !password.isEmpty
            else { continue }
            return password
        }
        return nil
    }
}
