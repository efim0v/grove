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

public struct CmuxService: Sendable {
    private let runner: any CommandRunning
    private let cmuxPath: String?
    /// cmux's own config file used to resolve automation.socketPassword;
    /// nil = the real ~/.config/cmux locations. Test seam.
    private let configFile: String?
    /// Raw-socket denial probe (see readSocketGreeting). Test seam.
    private let socketGreeting: @Sendable (String) -> String?

    static let fallbackPath = "/Applications/cmux.app/Contents/Resources/bin/cmux"
    static let bundleID = "com.cmuxterm.app"

    public init(runner: any CommandRunning = ProcessRunner(), cmuxPath: String? = nil) {
        self.init(runner: runner, cmuxPath: cmuxPath, configFile: nil,
                  socketGreeting: { Self.readSocketGreeting(path: $0) })
    }

    /// Full-seam init for tests: configFile feeds password resolution,
    /// socketGreeting replaces the raw-socket denial probe.
    init(runner: any CommandRunning, cmuxPath: String?, configFile: String?,
         socketGreeting: @escaping @Sendable (String) -> String?) {
        self.runner = runner
        self.cmuxPath = cmuxPath
        self.configFile = configFile
        self.socketGreeting = socketGreeting
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
        await pingResult().ok
    }

    /// ping with the failure detail preserved (ping() collapses it to a Bool).
    func pingResult() async -> (ok: Bool, detail: String?) {
        do {
            let result = try await runner.run(executable, ["ping"], cwd: nil, env: passwordEnv(), timeout: 10)
            if result.exitCode == 0
                && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "PONG" {
                return (true, nil)
            }
            let firstErrorLine = result.stderr
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").first.map(String.init) ?? ""
            return (false, "ping exit=\(result.exitCode)"
                        + (firstErrorLine.isEmpty ? "" : ": \(firstErrorLine)"))
        } catch {
            return (false, "ping failed: \(error)")
        }
    }

    public func ensureRunning() async throws {
        var last = await pingResult()
        if last.ok { return }
        // cmux may be RUNNING but refusing us: its control socket rejects
        // clients not descended from cmux unless the user allows external
        // automation (socketControlMode). Launching + waiting 10s would only
        // bury that in a misleading timeout — fail fast with the real reason.
        if let denial = socketDenial() {
            throw GroveError.cmuxUnavailable(Self.denialMessage(denial))
        }
        _ = try? await runner.run("/usr/bin/open", ["-b", Self.bundleID], cwd: nil, env: nil, timeout: 10)
        let deadline = Date().addingTimeInterval(10)
        while true {
            last = await pingResult()
            if last.ok { return }
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        // A cmux we just launched comes up in "cmuxOnly" mode too: prefer the
        // actionable denial message over a generic timeout.
        if let denial = socketDenial() {
            throw GroveError.cmuxUnavailable(Self.denialMessage(denial))
        }
        let detail = last.detail.map { " (last \($0))" } ?? ""
        throw GroveError.cmuxUnavailable(
            "cmux did not answer ping within 10s after launching \(Self.bundleID)\(detail)")
    }

    /// Runs a cmux CLI command. The CLI reports a server-side hangup only as
    /// "Failed to write to socket (Broken pipe)" — when that happens, ask the
    /// socket directly whether the server DENIED us and convert the opaque
    /// process failure into the actionable error.
    private func runCmux(_ args: [String]) async throws -> ProcessResult {
        do {
            return try await runner.runOK(executable, args, cwd: nil, env: passwordEnv(), timeout: 10)
        } catch GroveError.processFailed(let command, let exitCode, let stderr)
            where stderr.contains("Failed to write to socket") || stderr.contains("Broken pipe") {
            if let denial = socketDenial() {
                throw GroveError.cmuxUnavailable(Self.denialMessage(denial))
            }
            throw GroveError.processFailed(command: command, exitCode: exitCode, stderr: stderr)
        }
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

    public func listWorkspaces() async throws -> [CmuxWorkspace] {
        let result = try await runCmux(["rpc", "workspace.list", "{}"])
        let data = Data(result.stdout.utf8)
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
        var args = ["new-workspace", "--name", name, "--cwd", cwd]
        if let command { args += ["--command", command] }
        args += ["--focus", focus ? "true" : "false"]
        _ = try await runCmux(args)
        if focus { try await activateApp() }
    }

    public func selectWorkspace(_ idOrRef: String) async throws {
        _ = try await runCmux(["select-workspace", "--workspace", idOrRef])
        try await activateApp()
    }

    public func closeWorkspace(_ idOrRef: String) async throws {
        _ = try await runCmux(["close-workspace", "--workspace", idOrRef])
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
