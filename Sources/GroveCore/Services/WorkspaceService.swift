import Foundation

// MARK: - Snapshot model

public struct WorkspaceRepoState: Sendable {
    public let repo: RepoInfo
    public let entry: WorktreeEntry
    public let meta: WorktreeMeta?
    public let scanError: String?
}

public struct FeatureWorkspace: Sendable {
    public let name: String
    public let umbrellaPath: String
    public let repos: [WorkspaceRepoState]
    /// Stacking parent; nil = forked from base. DERIVED from git, never stored.
    public let parentName: String?
    public let sessions: [ClaudeSession]
    public let liveProcesses: [LiveProcess]
    public let cmuxWorkspaces: [CmuxWorkspace]
}

public struct LooseWorktree: Sendable {
    public let repo: RepoInfo
    public let entry: WorktreeEntry
    public let meta: WorktreeMeta?
    public let sessions: [ClaudeSession]
    public let liveProcesses: [LiveProcess]
    public let cmuxWorkspaces: [CmuxWorkspace]
}

public struct ProjectSnapshot: Sendable {
    public let project: ProjectConfig
    public let repos: [RepoInfo]
    public let workspaces: [FeatureWorkspace]
    public let loose: [LooseWorktree]
    public let errors: [String]
}

public struct CreatedArtifact: Sendable {
    public let repoPath: String
    public let worktreePath: String
    public let branch: String
    public let branchWasCreated: Bool
}

public struct CreationReport: Sendable {
    public let artifacts: [CreatedArtifact]
    public let logLines: [String]
    public let failure: String?
}

// MARK: - Parent resolution (pure)

/// Deepest fork point wins; on equal depth the alphabetically first name wins.
public func resolveParentName(candidates: [(name: String, depth: Int)]) -> String? {
    candidates
        .sorted { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
            return lhs.name < rhs.name
        }
        .first?.name
}

// MARK: - WorkspaceService

public struct WorkspaceService {
    let git: GitService
    let claude: ClaudeService
    let cmux: CmuxService
    let config: GroveConfig

    public init(git: GitService, claude: ClaudeService, cmux: CmuxService, config: GroveConfig) {
        self.git = git
        self.claude = claude
        self.cmux = cmux
        self.config = config
    }

    public func workspacesRoot(for project: ProjectConfig) -> String {
        let raw = project.workspacesRoot
            ?? config.workspacesRootTemplate.replacingOccurrences(of: "{project}", with: project.name)
        return expandTilde(raw)
    }

    /// Foundation-canonical form of a path so comparisons survive macOS
    /// /var -> /private/var symlinks: git reports realpaths (/private/var/...),
    /// resolvingSymlinksInPath() maps both forms to the /var/... spelling.
    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: expandTilde(path)).resolvingSymlinksInPath().path
    }

    /// Result of listing one repo's worktrees inside the scan task group.
    ///
    /// WORKAROUND (Swift 6.3.2 release builds): this used to be the bare tuple
    /// `(RepoInfo, [WorktreeEntry], String?)` with the child task returning
    /// `(repo, try await git.worktrees(repo: repo), nil)` inside a do/catch.
    /// Under -O that exact closure shape is miscompiled: the child's future
    /// result is silently dropped (scan saw ZERO worktrees -> zero workspaces)
    /// and the CLI intermittently aborts with
    /// "libc++abi: Pure virtual function called!" in
    /// swift::AsyncTask::completeFuture. Reproduced with a pure-Swift
    /// CommandRunning stub (no Process/AsyncStream involved), so the trigger is
    /// the closure/result shape, not ProcessRunner. A named Sendable result
    /// struct + hoisting the awaited call into a local avoids the broken
    /// codegen. Regression-covered by ScanWorktreeCollectionTests (release CI).
    struct WorktreeScanResult: Sendable {
        let repo: RepoInfo
        let entries: [WorktreeEntry]
        let error: String?
    }

    /// Lists worktrees of every repo in parallel. Failures degrade to error
    /// strings ("worktrees <dir>: <error>"), never throw.
    func collectWorktrees(repos: [RepoInfo]) async -> (byRepo: [RepoInfo: [WorktreeEntry]], errors: [String]) {
        let git = self.git
        var byRepo: [RepoInfo: [WorktreeEntry]] = [:]
        var errors: [String] = []
        await withTaskGroup(of: WorktreeScanResult.self) { group in
            for repo in repos {
                group.addTask {
                    do {
                        let entries = try await git.worktrees(repo: repo)
                        return WorktreeScanResult(repo: repo, entries: entries, error: nil)
                    } catch {
                        return WorktreeScanResult(repo: repo, entries: [], error: String(describing: error))
                    }
                }
            }
            for await result in group {
                byRepo[result.repo] = result.entries
                if let error = result.error {
                    errors.append("worktrees \(result.repo.dirName): \(error)")
                }
            }
        }
        return (byRepo, errors)
    }

    public func scan(project: ProjectConfig) async -> ProjectSnapshot {
        var errors: [String] = []
        let git = self.git
        let root = canonical(workspacesRoot(for: project))
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        let projectPath = canonical(project.path)

        // The workspaces root is excluded from discovery (spec §2): worktree
        // checkouts inside it must never be mistaken for project repos.
        let repos = await git.discoverRepos(projectPath: projectPath,
                                            scanDepth: project.scanDepth,
                                            excluded: Set(project.excludedRepos).union([root]))

        // Worktrees of every repo, in parallel.
        let (worktreesByRepo, worktreeErrors) = await collectWorktrees(repos: repos)
        errors.append(contentsOf: worktreeErrors)

        // Base branch per repo (override -> origin/HEAD -> main/master/dev).
        var baseByRepo: [String: String] = [:]   // repo.path -> base branch
        for repo in repos {
            baseByRepo[repo.path] = await git.baseBranch(repo: repo,
                                                         override: project.baseBranchOverrides[repo.dirName])
        }

        // Classify non-main worktrees: under workspaces root -> feature workspace member
        // (grouped by umbrella subdir name); anything else -> loose.
        struct Member {
            let repo: RepoInfo
            let entry: WorktreeEntry
        }
        var membersByName: [String: [Member]] = [:]
        var looseMembers: [Member] = []
        for repo in repos.sorted(by: { $0.path < $1.path }) {
            for entry in worktreesByRepo[repo] ?? [] where !entry.isMain {
                let path = canonical(entry.path)
                if path.hasPrefix(rootPrefix) {
                    let name = path.dropFirst(rootPrefix.count).split(separator: "/").first.map(String.init) ?? ""
                    if name.isEmpty { continue }
                    membersByName[name, default: []].append(Member(repo: repo, entry: entry))
                } else {
                    looseMembers.append(Member(repo: repo, entry: entry))
                }
            }
        }

        // Stacking: B is stacked on A when, in a shared repo, merge-base(B, A)
        // differs from merge-base(B, base) AND is not B's own tip (merge-base is
        // symmetric; the tip check rejects the reverse direction — an ancestor
        // is not a child). Depth = rev-list --count base..mergeBase.
        let names = membersByName.keys.sorted()
        var parentByName: [String: String] = [:]
        for childName in names {
            var candidates: [(name: String, depth: Int)] = []
            for candidateName in names where candidateName != childName {
                for member in membersByName[childName] ?? [] {
                    guard let childBranch = member.entry.branch,
                          let candidateMember = (membersByName[candidateName] ?? [])
                              .first(where: { $0.repo == member.repo }),
                          let candidateBranch = candidateMember.entry.branch
                    else { continue }
                    let repoPath = member.repo.path
                    let base = baseByRepo[repoPath] ?? "main"
                    guard let mb = await git.mergeBase(repoPath: repoPath, childBranch, candidateBranch) else { continue }
                    let mbBase = await git.mergeBase(repoPath: repoPath, childBranch, base)
                    guard mb != mbBase, mb != member.entry.head else { continue }
                    let depth = await git.revListCount(repoPath: repoPath, from: base, to: mb) ?? 0
                    candidates.append((name: candidateName, depth: depth))
                }
            }
            if let parent = resolveParentName(candidates: candidates) {
                parentByName[childName] = parent
            }
        }

        // cmux mapping: failures become snapshot errors, never throw.
        var cmuxList: [CmuxWorkspace] = []
        do {
            cmuxList = try await cmux.listWorkspaces()
        } catch {
            errors.append("cmux: \(error)")
        }

        // Live Claude processes are path-INdependent (each call re-lists the
        // sessions directory and probes every pid), so list them exactly once
        // and filter per path below — one consistent snapshot for the whole
        // scan. sessions(for:) IS cwd-keyed and stays per-path.
        let allLiveProcesses = config.accounts.flatMap { claude.liveProcesses(account: $0) }

        // Assemble feature workspaces (meta relative to parent branch when stacked).
        var workspaces: [FeatureWorkspace] = []
        for name in names {
            let umbrella = rootPrefix + name
            let parent = parentByName[name]
            var repoStates: [WorkspaceRepoState] = []
            for member in (membersByName[name] ?? []).sorted(by: { $0.repo.dirName < $1.repo.dirName }) {
                let base = baseByRepo[member.repo.path] ?? "main"
                var relativeTo = base
                if let parent,
                   let parentMember = (membersByName[parent] ?? []).first(where: { $0.repo == member.repo }),
                   let parentBranch = parentMember.entry.branch {
                    relativeTo = parentBranch
                }
                let meta = await git.meta(repoPath: member.repo.path, worktree: member.entry, relativeTo: relativeTo)
                repoStates.append(WorkspaceRepoState(repo: member.repo, entry: member.entry,
                                                     meta: meta, scanError: nil))
            }
            let sessions = config.accounts
                .flatMap { claude.sessions(for: umbrella, account: $0) }
                .sorted { $0.lastActivity > $1.lastActivity }
            let live = allLiveProcesses.filter {
                let cwd = canonical($0.cwd)
                return cwd == umbrella || cwd.hasPrefix(umbrella + "/")
            }
            let matched = cmuxList.filter {
                let dir = canonical($0.currentDirectory)
                return dir == umbrella || dir.hasPrefix(umbrella + "/")
            }
            workspaces.append(FeatureWorkspace(name: name,
                                               umbrellaPath: umbrella,
                                               repos: repoStates,
                                               parentName: parent,
                                               sessions: sessions,
                                               liveProcesses: live,
                                               cmuxWorkspaces: matched))
        }

        // Assemble loose worktrees (meta relative to base; sessions keyed by worktree path).
        var loose: [LooseWorktree] = []
        for member in looseMembers.sorted(by: { $0.entry.path < $1.entry.path }) {
            let base = baseByRepo[member.repo.path] ?? "main"
            let meta = await git.meta(repoPath: member.repo.path, worktree: member.entry, relativeTo: base)
            let cwd = canonical(member.entry.path)
            let sessions = config.accounts
                .flatMap { claude.sessions(for: cwd, account: $0) }
                .sorted { $0.lastActivity > $1.lastActivity }
            let live = allLiveProcesses.filter { canonical($0.cwd) == cwd }
            // cmux matching for loose worktrees: exact directory equality (spec §2:
            // all Claude/cmux actions are available for loose worktrees too).
            let matched = cmuxList.filter { canonical($0.currentDirectory) == cwd }
            loose.append(LooseWorktree(repo: member.repo, entry: member.entry, meta: meta,
                                       sessions: sessions, liveProcesses: live,
                                       cmuxWorkspaces: matched))
        }

        return ProjectSnapshot(project: project,
                               repos: repos,
                               workspaces: workspaces,
                               loose: loose,
                               errors: errors)
    }

    // MARK: - Creation

    public func createWorkspace(project: ProjectConfig, name: String, branch: String,
                                repos: [RepoInfo], forkFrom parent: FeatureWorkspace?) async -> CreationReport {
        var logLines: [String] = []
        var artifacts: [CreatedArtifact] = []
        let fm = FileManager.default

        // 1. Validate the name BEFORE touching the filesystem or git.
        guard name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return CreationReport(artifacts: [], logLines: ["invalid workspace name: \(name)"],
                                  failure: GroveError.invalidWorkspaceName(name).description)
        }

        let root = workspacesRoot(for: project)
        let umbrella = (root as NSString).appendingPathComponent(name)

        // 2. The umbrella must not already host a workspace (checked BEFORE any git op).
        //    A directory entry inside the umbrella means an existing workspace -> refuse.
        //    A stray plain FILE does not constitute a workspace; git itself will refuse
        //    to overwrite it when adding the worktree for that repo.
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: umbrella, isDirectory: &isDir) {
            if !isDir.boolValue {
                return CreationReport(artifacts: [], logLines: ["a file exists at \(umbrella)"],
                                      failure: GroveError.workspaceExists(umbrella).description)
            }
            let entries = (try? fm.contentsOfDirectory(atPath: umbrella)) ?? []
            for entry in entries {
                var entryIsDir: ObjCBool = false
                let entryPath = (umbrella as NSString).appendingPathComponent(entry)
                if fm.fileExists(atPath: entryPath, isDirectory: &entryIsDir), entryIsDir.boolValue {
                    return CreationReport(artifacts: [], logLines: ["umbrella already contains \(entry)/"],
                                          failure: GroveError.workspaceExists(umbrella).description)
                }
            }
        } else {
            do {
                try fm.createDirectory(atPath: umbrella, withIntermediateDirectories: true)
            } catch {
                return CreationReport(artifacts: [], logLines: [],
                                      failure: "cannot create \(umbrella): \(error.localizedDescription)")
            }
        }
        logLines.append("umbrella: \(umbrella)")

        // 3. Sequentially add one worktree per repo; stop on the first failure.
        for repo in repos {
            let base = await git.baseBranch(repo: repo, override: project.baseBranchOverrides[repo.dirName])
            var startPoint = base
            if let parent,
               let parentState = parent.repos.first(where: { $0.repo.path == repo.path }),
               let parentBranch = parentState.entry.branch {
                startPoint = parentBranch
            }
            let worktreePath = (umbrella as NSString).appendingPathComponent(repo.dirName)
            let exists = await git.branchExists(repoPath: repo.path, branch)
            let createBranch = !exists
            do {
                try await git.addWorktree(repoPath: repo.path, branch: branch, startPoint: startPoint,
                                          at: worktreePath, createBranch: createBranch)
                artifacts.append(CreatedArtifact(repoPath: repo.path, worktreePath: worktreePath,
                                                 branch: branch, branchWasCreated: createBranch))
                logLines.append("[\(repo.dirName)] worktree \(worktreePath) on \(branch) from \(startPoint)")
            } catch {
                logLines.append("[\(repo.dirName)] worktree add failed: \(error)")
                // `git worktree add -b` creates the branch BEFORE validating the
                // target path, so a failed add can leave the new branch behind.
                // Best-effort delete so the failed repo contributes no artifacts.
                if createBranch, await git.branchExists(repoPath: repo.path, branch) {
                    if (try? await git.deleteBranch(repoPath: repo.path, branch)) != nil {
                        logLines.append("[\(repo.dirName)] removed stray branch \(branch)")
                    }
                }
                return CreationReport(artifacts: artifacts, logLines: logLines,
                                      failure: "worktree add failed in \(repo.dirName): \(error)")
            }
        }

        // 4. Post-create hooks, concurrently; failures are logged, never fatal.
        let hooks = project.postCreateHooks
        let hookJobs: [(dirName: String, command: String, cwd: String)] = artifacts.compactMap { artifact in
            let dirName = (artifact.worktreePath as NSString).lastPathComponent
            guard let command = hooks[dirName] else { return nil }
            return (dirName, command, artifact.worktreePath)
        }
        if !hookJobs.isEmpty {
            let hookLines = await withTaskGroup(of: [String].self) { group -> [String] in
                for job in hookJobs {
                    group.addTask {
                        let runner = ProcessRunner()
                        var lines = ["[\(job.dirName)] hook: \(job.command)"]
                        do {
                            let result = try await runner.run("/bin/zsh", ["-lc", job.command],
                                                              cwd: job.cwd, env: nil, timeout: 300)
                            let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !out.isEmpty { lines.append("[\(job.dirName)] \(out)") }
                            if !err.isEmpty { lines.append("[\(job.dirName)] \(err)") }
                            if result.exitCode != 0 {
                                lines.append("[\(job.dirName)] hook failed with exit \(result.exitCode)")
                            } else {
                                lines.append("[\(job.dirName)] hook ok")
                            }
                        } catch {
                            lines.append("[\(job.dirName)] hook error: \(error)")
                        }
                        return lines
                    }
                }
                var collected: [String] = []
                for await lines in group { collected.append(contentsOf: lines) }
                return collected
            }
            logLines.append(contentsOf: hookLines)
        }

        return CreationReport(artifacts: artifacts, logLines: logLines, failure: nil)
    }

    // MARK: - Rollback (only ever touches artifacts of the current creation run)

    public func rollback(_ artifacts: [CreatedArtifact]) async -> [String] {
        var log: [String] = []
        for artifact in artifacts.reversed() {
            do {
                try await git.removeWorktree(repoPath: artifact.repoPath, at: artifact.worktreePath, force: true)
                log.append("removed worktree \(artifact.worktreePath)")
            } catch {
                log.append("failed to remove worktree \(artifact.worktreePath): \(error)")
            }
            if artifact.branchWasCreated {
                do {
                    try await git.deleteBranch(repoPath: artifact.repoPath, artifact.branch)
                    log.append("deleted branch \(artifact.branch) in \(artifact.repoPath)")
                } catch {
                    log.append("failed to delete branch \(artifact.branch): \(error)")
                }
            }
        }
        let fm = FileManager.default
        let umbrellas = Set(artifacts.map { ($0.worktreePath as NSString).deletingLastPathComponent })
        for umbrella in umbrellas.sorted() {
            let entries = ((try? fm.contentsOfDirectory(atPath: umbrella)) ?? []).filter { $0 != ".DS_Store" }
            if entries.isEmpty {
                try? fm.removeItem(atPath: umbrella)
                log.append("removed empty umbrella \(umbrella)")
            } else {
                log.append("kept umbrella \(umbrella) (not empty)")
            }
        }
        return log
    }
}
