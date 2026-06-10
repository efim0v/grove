import Foundation
import GroveCore

// MARK: - Codable mirrors of GroveCore types (core types are not Codable by contract)

struct RepoJSON: Codable {
    let path: String
    let dirName: String
}

struct WorktreeJSON: Codable {
    let path: String
    let branch: String?
    let head: String
    let isMain: Bool
}

struct MetaJSON: Codable {
    let baseBranch: String
    let forkPoint: String?
    let forkDate: Date?
    let ahead: Int
    let behind: Int
    let dirtyCount: Int
    let lastCommitDate: Date?
    let lastCommitSubject: String?
}

struct WorkspaceRepoJSON: Codable {
    let repo: RepoJSON
    let worktree: WorktreeJSON
    let meta: MetaJSON?
    let scanError: String?
}

struct SessionJSON: Codable {
    let id: String
    let cwd: String
    let title: String?
    let lastActivity: Date
    let accountName: String
    let gitBranch: String?
    let live: Bool
    let liveStatus: String?
}

struct WorkspaceJSON: Codable {
    let name: String
    let umbrellaPath: String
    let parentName: String?
    let repos: [WorkspaceRepoJSON]
    let sessions: [SessionJSON]
    let liveCount: Int
}

struct LooseJSON: Codable {
    let repo: RepoJSON
    let worktree: WorktreeJSON
    let meta: MetaJSON?
}

struct SnapshotJSON: Codable {
    let project: String
    let path: String
    let repos: [RepoJSON]
    let workspaces: [WorkspaceJSON]
    let loose: [LooseJSON]
    let errors: [String]
}

struct RepoScanJSON: Codable {
    let repo: RepoJSON
    let worktrees: [WorktreeJSON]
    let error: String?
}

struct ScanJSON: Codable {
    let path: String
    let repos: [RepoScanJSON]
}

struct ArtifactJSON: Codable {
    let repoPath: String
    let worktreePath: String
    let branch: String
    let branchWasCreated: Bool
}

struct CreateJSON: Codable {
    let artifacts: [ArtifactJSON]
    let logLines: [String]
    let failure: String?
}

struct CommitJSON: Codable {
    let hash: String
    let parents: [String]
    let author: String
    let date: Date
    let refs: [String]
    let subject: String
    let lane: Int
}

struct ToolJSON: Codable {
    let name: String
    let found: Bool
    let version: String?
}

struct DoctorJSON: Codable {
    let tools: [ToolJSON]
}

// MARK: - mapping

func repoJSON(_ repo: RepoInfo) -> RepoJSON {
    RepoJSON(path: repo.path, dirName: repo.dirName)
}

func worktreeJSON(_ entry: WorktreeEntry) -> WorktreeJSON {
    WorktreeJSON(path: entry.path, branch: entry.branch, head: entry.head, isMain: entry.isMain)
}

func metaJSON(_ meta: WorktreeMeta?) -> MetaJSON? {
    guard let meta else { return nil }
    return MetaJSON(baseBranch: meta.baseBranch, forkPoint: meta.forkPoint, forkDate: meta.forkDate,
                    ahead: meta.ahead, behind: meta.behind, dirtyCount: meta.dirtyCount,
                    lastCommitDate: meta.lastCommitDate, lastCommitSubject: meta.lastCommitSubject)
}

func sessionJSON(_ session: ClaudeSession, live: [LiveProcess]) -> SessionJSON {
    let match = live.first { $0.sessionId == session.id }
    return SessionJSON(id: session.id, cwd: session.cwd, title: session.title,
                       lastActivity: session.lastActivity, accountName: session.accountName,
                       gitBranch: session.gitBranch, live: match != nil, liveStatus: match?.status)
}

func workspaceJSON(_ workspace: FeatureWorkspace) -> WorkspaceJSON {
    WorkspaceJSON(
        name: workspace.name,
        umbrellaPath: workspace.umbrellaPath,
        parentName: workspace.parentName,
        repos: workspace.repos.map {
            WorkspaceRepoJSON(repo: repoJSON($0.repo), worktree: worktreeJSON($0.entry),
                              meta: metaJSON($0.meta), scanError: $0.scanError)
        },
        sessions: workspace.sessions.map { sessionJSON($0, live: workspace.liveProcesses) },
        liveCount: workspace.liveProcesses.count)
}

func snapshotJSON(_ snapshot: ProjectSnapshot) -> SnapshotJSON {
    SnapshotJSON(
        project: snapshot.project.name,
        path: snapshot.project.path,
        repos: snapshot.repos.map(repoJSON),
        workspaces: snapshot.workspaces.map(workspaceJSON),
        loose: snapshot.loose.map {
            LooseJSON(repo: repoJSON($0.repo), worktree: worktreeJSON($0.entry), meta: metaJSON($0.meta))
        },
        errors: snapshot.errors)
}

func createJSON(_ report: CreationReport) -> CreateJSON {
    CreateJSON(
        artifacts: report.artifacts.map {
            ArtifactJSON(repoPath: $0.repoPath, worktreePath: $0.worktreePath,
                         branch: $0.branch, branchWasCreated: $0.branchWasCreated)
        },
        logLines: report.logLines,
        failure: report.failure)
}

func commitJSON(_ node: CommitNode) -> CommitJSON {
    CommitJSON(hash: node.hash, parents: node.parents, author: node.author,
               date: node.date, refs: node.refs, subject: node.subject, lane: node.lane)
}
