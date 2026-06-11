import Foundation
import GroveCore

public enum MainTab: String, CaseIterable {
    case workspaces
    case graph
    case accounts
}

/// Observable app state shared by every view. Task 15 ships the stored
/// properties, config loading and selection helpers; Task 17 adds refresh(),
/// config mutations and the cmux/Claude action methods.
@MainActor
public final class AppState: ObservableObject {
    @Published public var config: GroveConfig
    @Published public var configIssue: String?
    @Published public var snapshots: [UUID: ProjectSnapshot] = [:]
    @Published public var selectedProjectID: UUID?
    @Published public var selectedTab: MainTab = .workspaces
    @Published public var searchQuery: String = ""
    @Published public var isScanning: Bool = false
    @Published public var actionError: String?
    @Published public var graphRepoPath: String?
    @Published public var graphNodes: [CommitNode] = []

    let configStore: ConfigStore

    public init(configStore: ConfigStore) {
        self.configStore = configStore
        let (config, issue) = configStore.load()
        self.config = config
        self.configIssue = issue
        self.selectedProjectID = config.projects.first?.id
    }

    /// Real config path: ~/Library/Application Support/Grove/config.json.
    public convenience init() {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grove/config.json")
        self.init(configStore: ConfigStore(url: url))
    }

    public var selectedProject: ProjectConfig? {
        config.projects.first { $0.id == selectedProjectID }
    }

    public var selectedSnapshot: ProjectSnapshot? {
        selectedProjectID.flatMap { snapshots[$0] }
    }
}
