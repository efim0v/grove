public enum GroveError: Error, CustomStringConvertible {
    case processFailed(command: String, exitCode: Int32, stderr: String)
    case timeout(command: String)
    case invalidWorkspaceName(String)
    case workspaceExists(String)
    case cmuxUnavailable(String)
    case io(String)

    public var description: String {
        switch self {
        case .processFailed(let command, let exitCode, let stderr):
            return "command failed (exit \(exitCode)): \(command)\n\(stderr)"
        case .timeout(let command):
            return "command timed out: \(command)"
        case .invalidWorkspaceName(let name):
            return "invalid workspace name '\(name)' (allowed: letters, digits, '.', '_', '-')"
        case .workspaceExists(let path):
            return "workspace already exists: \(path)"
        case .cmuxUnavailable(let message):
            return "cmux unavailable: \(message)"
        case .io(let message):
            return "I/O error: \(message)"
        }
    }
}
