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
        var worktreesByRepo: [RepoInfo: [WorktreeEntry]] = [:]
        await withTaskGroup(of: (RepoInfo, [WorktreeEntry], String?).self) { group in
            for repo in repos {
                group.addTask {
                    do { return (repo, try await git.worktrees(repo: repo), nil) }
                    catch { return (repo, [], String(describing: error)) }
                }
            }
            for await (repo, entries, error) in group {
                worktreesByRepo[repo] = entries
                if let error { errors.append("worktrees \(repo.dirName): \(error)") }
            }
        }

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
}
