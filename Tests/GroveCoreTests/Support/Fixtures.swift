import Foundation

enum Fixture {
    /// Unique directory under the system temporary directory. Callers need not clean up.
    static func tempDir(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs `command` via /bin/zsh -c. Throws (with stderr in the message) on non-zero exit; returns stdout.
    @discardableResult
    static func sh(_ command: String, cwd: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        if let cwd { process.currentDirectoryURL = cwd }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "Fixture",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "fixture command failed (exit \(process.terminationStatus)): \(command)\nstderr: \(stderr)"
                ]
            )
        }
        return stdout
    }

    /// git init -q -b <defaultBranch>; config user.email t@t / user.name t; initial commit "base" adding base.txt.
    static func makeRepo(in parent: URL, name: String, defaultBranch: String = "main") throws -> URL {
        let repo = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try sh("git init -q -b \(q(defaultBranch))", cwd: repo)
        try sh("git config user.email t@t && git config user.name t", cwd: repo)
        try "base\n".write(to: repo.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try sh("git add base.txt && git commit -qm base", cwd: repo)
        return repo
    }

    static func commit(repo: URL, file: String, content: String, message: String) throws {
        let fileURL = repo.appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        try sh("git add \(q(file)) && git commit -qm \(q(message))", cwd: repo)
    }

    static func addWorktree(repo: URL, branch: String, from start: String, at path: URL) throws {
        try sh("git -C \(q(repo.path)) worktree add -b \(q(branch)) \(q(path.path)) \(q(start))")
    }

    /// POSIX single-quote shell quoting. Deliberately duplicated from GroveCore:
    /// test fixtures must not depend on the code under test.
    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
