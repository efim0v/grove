import Foundation

public struct CmuxWorkspace: Sendable, Equatable {
    public let id: String
    public let title: String
    public let currentDirectory: String
}

public struct CmuxService: Sendable {
    private let runner: any CommandRunning
    private let cmuxPath: String?

    static let fallbackPath = "/Applications/cmux.app/Contents/Resources/bin/cmux"
    static let bundleID = "com.cmuxterm.app"

    public init(runner: any CommandRunning = ProcessRunner(), cmuxPath: String? = nil) {
        self.runner = runner
        self.cmuxPath = cmuxPath
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
        guard let result = try? await runner.run(executable, ["ping"], cwd: nil, env: nil, timeout: 10) else {
            return false
        }
        return result.exitCode == 0
            && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "PONG"
    }

    public func ensureRunning() async throws {
        if await ping() { return }
        _ = try? await runner.run("/usr/bin/open", ["-b", Self.bundleID], cwd: nil, env: nil, timeout: 10)
        let deadline = Date().addingTimeInterval(10)
        while true {
            if await ping() { return }
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw GroveError.cmuxUnavailable("cmux did not answer ping within 10s after launching \(Self.bundleID)")
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
        let result = try await runner.runOK(executable, ["rpc", "workspace.list", "{}"], cwd: nil, env: nil, timeout: 10)
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

    public func newWorkspace(name: String, cwd: String, command: String?, focus: Bool) async throws {
        var args = ["new-workspace", "--name", name, "--cwd", cwd]
        if let command { args += ["--command", command] }
        args += ["--focus", focus ? "true" : "false"]
        _ = try await runner.runOK(executable, args, cwd: nil, env: nil, timeout: 10)
    }

    public func selectWorkspace(_ idOrRef: String) async throws {
        _ = try await runner.runOK(executable, ["select-workspace", "--workspace", idOrRef], cwd: nil, env: nil, timeout: 10)
        _ = try await runner.runOK("/usr/bin/open", ["-b", Self.bundleID], cwd: nil, env: nil, timeout: 10)
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
