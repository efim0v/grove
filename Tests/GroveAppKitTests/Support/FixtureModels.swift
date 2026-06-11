import Foundation
import GroveCore

/// Synthetic snapshot-model builders for pure presentation tests. Everything
/// is constructed through GroveCore's public memberwise inits — no disk, no
/// git, no processes. A fixed `now` keeps every age computation deterministic.
enum Fix {
    /// Arbitrary fixed instant; all fixture dates are offsets from this.
    static let now = Date(timeIntervalSince1970: 1_750_000_000)

    static func days(_ n: Double) -> TimeInterval { n * 86_400 }

    static func repoState(
        dirName: String = "alpha",
        branch: String? = "feat/x",
        forkDate: Date? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        dirty: Int = 0,
        hasMeta: Bool = true
    ) -> WorkspaceRepoState {
        let repo = RepoInfo(path: "/proj/\(dirName)", dirName: dirName)
        let entry = WorktreeEntry(path: "/ws/feature/\(dirName)", branch: branch,
                                  head: "deadbeef", isMain: false)
        let meta: WorktreeMeta? = hasMeta
            ? WorktreeMeta(baseBranch: "main", forkPoint: "f0", forkDate: forkDate,
                           ahead: ahead, behind: behind, dirtyCount: dirty,
                           lastCommitDate: forkDate, lastCommitSubject: "subject")
            : nil
        return WorkspaceRepoState(repo: repo, entry: entry, meta: meta, scanError: nil)
    }

    static func workspace(
        name: String,
        parent: String? = nil,
        repos: [WorkspaceRepoState] = [Fix.repoState()],
        sessions: [ClaudeSession] = [],
        live: [LiveProcess] = []
    ) -> FeatureWorkspace {
        FeatureWorkspace(name: name, umbrellaPath: "/ws/\(name)", repos: repos,
                         parentName: parent, sessions: sessions,
                         liveProcesses: live, cmuxWorkspaces: [])
    }

    static func session(
        id: String,
        cwd: String = "/ws/feature",
        title: String? = nil,
        age: TimeInterval = 0,
        account: String = "default"
    ) -> ClaudeSession {
        ClaudeSession(id: id, cwd: cwd, title: title,
                      lastActivity: now.addingTimeInterval(-age),
                      accountName: account, gitBranch: nil)
    }

    static func live(
        pid: Int32,
        sessionId: String,
        status: String,
        cwd: String = "/ws/feature",
        account: String = "default"
    ) -> LiveProcess {
        LiveProcess(pid: pid, sessionId: sessionId, cwd: cwd,
                    status: status, accountName: account)
    }

    static func snapshot(workspaces: [FeatureWorkspace]) -> ProjectSnapshot {
        ProjectSnapshot(project: ProjectConfig(name: "demo", path: "/proj"),
                        repos: [], workspaces: workspaces, loose: [], errors: [])
    }
}
