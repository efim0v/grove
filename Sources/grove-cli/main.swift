import Foundation
import GroveCore

// MARK: - output helpers

func eprint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}

func printJSON<T: Encodable>(_ value: T) {
    do {
        let data = try makeEncoder().encode(value)
        print(String(decoding: data, as: UTF8.self))
    } catch {
        eprint("json encoding failed: \(error)")
        exit(1)
    }
}

// MARK: - hand-rolled argument parsing (no dependencies)

struct ParsedArgs {
    var positionals: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]
}

func parseArgs(_ args: [String], flagNames: Set<String>, optionNames: Set<String>) -> ParsedArgs? {
    var parsed = ParsedArgs()
    var index = 0
    while index < args.count {
        let arg = args[index]
        if flagNames.contains(arg) {
            parsed.flags.insert(arg)
        } else if optionNames.contains(arg) {
            guard index + 1 < args.count else {
                eprint("missing value for \(arg)")
                return nil
            }
            index += 1
            parsed.options[arg] = args[index]
        } else if arg.hasPrefix("--") {
            eprint("unknown option \(arg)")
            return nil
        } else {
            parsed.positionals.append(arg)
        }
        index += 1
    }
    return parsed
}

func absolutePath(_ path: String) -> String {
    URL(fileURLWithPath: expandTilde(path)).standardizedFileURL.path
}

func adhocProject(path: String) -> ProjectConfig {
    let abs = absolutePath(path)
    return ProjectConfig(name: URL(fileURLWithPath: abs).lastPathComponent, path: abs)
}

func makeWorkspaceService() -> WorkspaceService {
    WorkspaceService(git: GitService(), claude: ClaudeService(), cmux: CmuxService(),
                     config: GroveConfig.defaultConfig)
}

// MARK: - subcommands

func cmdScan(_ rest: [String]) async -> Int32 {
    guard let parsed = parseArgs(rest, flagNames: ["--json"], optionNames: []),
          parsed.positionals.count == 1 else {
        eprint("usage: grove scan <path> [--json]")
        return 2
    }
    let path = absolutePath(parsed.positionals[0])
    let git = GitService()
    let repos = await git.discoverRepos(projectPath: path, scanDepth: 3, excluded: [])
    var results: [RepoScanJSON] = []
    for repo in repos {
        do {
            let entries = try await git.worktrees(repo: repo)
            results.append(RepoScanJSON(repo: repoJSON(repo), worktrees: entries.map(worktreeJSON), error: nil))
        } catch {
            results.append(RepoScanJSON(repo: repoJSON(repo), worktrees: [], error: String(describing: error)))
        }
    }
    if parsed.flags.contains("--json") {
        printJSON(ScanJSON(path: path, repos: results))
    } else {
        print("\(path): \(repos.count) repo(s)")
        for result in results {
            print("● \(result.repo.dirName) — \(result.worktrees.count) worktree(s)")
            for worktree in result.worktrees {
                let branch = worktree.branch ?? "detached"
                let marker = worktree.isMain ? " (main checkout)" : ""
                print("    \(branch)  \(String(worktree.head.prefix(7)))  \(worktree.path)\(marker)")
            }
            if let error = result.error { print("    ⚠ \(error)") }
        }
    }
    return 0
}

func cmdWorkspaces(_ rest: [String]) async -> Int32 {
    guard let parsed = parseArgs(rest, flagNames: ["--json"], optionNames: []),
          parsed.positionals.count == 1 else {
        eprint("usage: grove workspaces <path> [--json]")
        return 2
    }
    let project = adhocProject(path: parsed.positionals[0])
    let snapshot = await makeWorkspaceService().scan(project: project)
    if parsed.flags.contains("--json") {
        printJSON(snapshotJSON(snapshot))
    } else {
        print(renderSnapshotTree(snapshot))
    }
    return 0
}

func cmdSessions(_ rest: [String]) async -> Int32 {
    guard let parsed = parseArgs(rest, flagNames: ["--json"], optionNames: []),
          parsed.positionals.count == 1 else {
        eprint("usage: grove sessions <cwd> [--json]")
        return 2
    }
    // Canonicalize the same way WorkspaceService.scan does, so /var vs
    // /private/var spellings of the same directory still match live processes.
    let cwd = canonicalPath(absolutePath(parsed.positionals[0]))
    let claude = ClaudeService()
    let accounts = GroveConfig.defaultConfig.accounts
    var sessions: [ClaudeSession] = []
    for account in accounts {
        sessions.append(contentsOf: claude.sessions(for: cwd, account: account))
    }
    // Single source of truth (file records ∪ process table), matched by session id
    // OR cwd so resumed (id, no cwd) and fresh (cwd, no id) sessions both resolve.
    let sessionIds = Set(sessions.map { $0.id })
    let live = claude.allLiveProcesses(accounts: accounts).filter { p in
        (!p.sessionId.isEmpty && sessionIds.contains(p.sessionId)) || canonicalPath(p.cwd) == cwd
    }
    sessions.sort { $0.lastActivity > $1.lastActivity }
    if parsed.flags.contains("--json") {
        printJSON(sessions.map { sessionJSON($0, live: live) })
    } else {
        print(renderSessions(sessions, live: live))
    }
    return 0
}

func cmdCreate(_ rest: [String]) async -> Int32 {
    // --from-branch is repeatable: we handle it manually before passing to parseArgs.
    // Collect all --from-branch <repoDir>=<branch> pairs, then remove them from argv.
    var startPointOverrides: [String: String] = [:]
    var filteredRest: [String] = []
    var idx = 0
    while idx < rest.count {
        if rest[idx] == "--from-branch" {
            idx += 1
            guard idx < rest.count else {
                eprint("missing value for --from-branch")
                return 2
            }
            let value = rest[idx]
            let parts = value.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                eprint("--from-branch value must be <repoDir>=<branch>, got: \(value)")
                return 2
            }
            startPointOverrides[String(parts[0])] = String(parts[1])
        } else {
            filteredRest.append(rest[idx])
        }
        idx += 1
    }

    guard let parsed = parseArgs(filteredRest, flagNames: ["--json"],
                                 optionNames: ["--repos", "--branch", "--from"]),
          parsed.positionals.count == 2 else {
        eprint("usage: grove create <path> <name> [--repos a,b] [--branch x] [--from workspace] [--from-branch <repoDir>=<branch>] [--json]")
        return 2
    }
    let project = adhocProject(path: parsed.positionals[0])
    let name = parsed.positionals[1]
    let service = makeWorkspaceService()
    let snapshot = await service.scan(project: project)

    var repos = snapshot.repos
    if let filter = parsed.options["--repos"] {
        let wanted = Set(filter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        repos = repos.filter { wanted.contains($0.dirName) }
        let found = Set(repos.map { $0.dirName })
        let missing = wanted.subtracting(found)
        if !missing.isEmpty {
            eprint("unknown repo(s): \(missing.sorted().joined(separator: ", "))")
            return 2
        }
    }
    if repos.isEmpty {
        eprint("no repos to include")
        return 2
    }

    let branch = parsed.options["--branch"]
        ?? project.branchTemplate.replacingOccurrences(of: "{name}", with: name)

    var parent: FeatureWorkspace? = nil
    if let fromName = parsed.options["--from"] {
        guard let found = snapshot.workspaces.first(where: { $0.name == fromName }) else {
            eprint("workspace not found: \(fromName)")
            return 2
        }
        parent = found
    }

    let report = await service.createWorkspace(project: project, name: name, branch: branch,
                                               repos: repos, forkFrom: parent,
                                               startPointOverrides: startPointOverrides)
    if parsed.flags.contains("--json") {
        printJSON(createJSON(report))
    } else {
        for line in report.logLines { print(line) }
        if let failure = report.failure {
            eprint("FAILED: \(failure)")
            if !report.artifacts.isEmpty {
                eprint("created so far (left in place; nothing is rolled back automatically):")
                for artifact in report.artifacts {
                    eprint("  \(artifact.worktreePath) [\(artifact.branch)]")
                }
            }
        } else {
            print("created workspace \(name) with \(report.artifacts.count) worktree(s)")
        }
    }
    return report.failure == nil ? 0 : 1
}

func cmdGraph(_ rest: [String]) async -> Int32 {
    guard let parsed = parseArgs(rest, flagNames: ["--json"], optionNames: ["--limit"]),
          parsed.positionals.count == 1 else {
        eprint("usage: grove graph <repoPath> [--limit N] [--json]")
        return 2
    }
    var limit = 300
    if let raw = parsed.options["--limit"] {
        guard let value = Int(raw), value > 0 else {
            eprint("--limit must be a positive integer")
            return 2
        }
        limit = value
    }
    let repoPath = absolutePath(parsed.positionals[0])
    do {
        let nodes = try await GitService().commitGraph(repoPath: repoPath, limit: limit, skip: 0)
        if parsed.flags.contains("--json") {
            printJSON(nodes.map(commitJSON))
        } else {
            print(renderGraph(nodes))
        }
        return 0
    } catch {
        eprint("graph failed: \(error)")
        return 1
    }
}

func checkTool(_ runner: ProcessRunner, name: String, candidates: [String]) async -> ToolJSON {
    for executable in candidates {
        do {
            let result = try await runner.run(executable, ["--version"], cwd: nil, env: nil, timeout: 10)
            if result.exitCode == 127 { continue }  // /usr/bin/env: command not found
            let version = result.stdout.split(separator: "\n").first.map(String.init)
            return ToolJSON(name: name, found: true, version: version)
        } catch {
            continue
        }
    }
    return ToolJSON(name: name, found: false, version: nil)
}

func cmdDoctor(_ rest: [String]) async -> Int32 {
    guard let parsed = parseArgs(rest, flagNames: ["--json"], optionNames: []) else {
        return 2
    }
    let runner = ProcessRunner()
    let home = NSHomeDirectory()
    var tools: [ToolJSON] = []
    tools.append(await checkTool(runner, name: "git", candidates: ["git"]))
    tools.append(await checkTool(runner, name: "claude",
                                 candidates: ["claude", "\(home)/.local/bin/claude"]))
    tools.append(await checkTool(runner, name: "cmux",
                                 candidates: ["cmux", "/Applications/cmux.app/Contents/Resources/bin/cmux"]))
    if parsed.flags.contains("--json") {
        printJSON(DoctorJSON(tools: tools))
    } else {
        for tool in tools {
            if tool.found {
                print("✓ \(tool.name)  \(tool.version ?? "(version unknown)")")
            } else {
                print("✗ \(tool.name)  not found")
            }
        }
    }
    return 0
}

// MARK: - dispatch (top-level code)

let usageText = """
grove — git-worktree / Claude Code orchestration

usage:
  grove scan <path> [--json]
  grove workspaces <path> [--json]
  grove sessions <cwd> [--json]
  grove create <path> <name> [--repos a,b] [--branch x] [--from workspace] [--from-branch <repoDir>=<branch>] [--json]
  grove graph <repoPath> [--limit N] [--json]
  grove doctor [--json]

create flags:
  --from-branch <repoDir>=<branch>   Fork a specific repo from <branch> instead of the default
                                     start point. Repeatable; takes precedence over --from.
"""

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    eprint(usageText)
    exit(2)
}
let rest = Array(argv.dropFirst())
let status: Int32
switch command {
case "scan":       status = await cmdScan(rest)
case "workspaces": status = await cmdWorkspaces(rest)
case "sessions":   status = await cmdSessions(rest)
case "create":     status = await cmdCreate(rest)
case "graph":      status = await cmdGraph(rest)
case "doctor":     status = await cmdDoctor(rest)
case "help", "--help", "-h":
    print(usageText)
    status = 0
default:
    eprint("unknown command: \(command)")
    eprint(usageText)
    status = 2
}
exit(status)
