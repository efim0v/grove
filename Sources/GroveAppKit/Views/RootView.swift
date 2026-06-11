import SwiftUI
import GroveCore

/// Panel root: sidebar of projects + tab strip + content + footer with Quit.
/// Task 15 placeholder: stub rows instead of the real screens. Task 19/21/22
/// replace the tab content with WorkspacesScreen / GraphScreen / AccountsScreen.
public struct RootView: View {
    @ObservedObject private var state: AppState

    public init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                content
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 520)
        .background(.black.opacity(0.35))
    }

    // Pure-SwiftUI tab strip. NOT Picker(.segmented): that control is
    // AppKit-backed and ImageRenderer draws it as an error placeholder offscreen.
    private var header: some View {
        HStack {
            Label("Grove", systemImage: "tree")
                .font(.headline)
            Spacer()
            HStack(spacing: 4) {
                ForEach(MainTab.allCases, id: \.rawValue) { tab in
                    Button {
                        state.selectedTab = tab
                    } label: {
                        Text(tab.rawValue.capitalized)
                            .font(.callout.weight(state.selectedTab == tab ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(state.selectedTab == tab ? AnyShapeStyle(.white.opacity(0.18))
                                                                 : AnyShapeStyle(.clear),
                                        in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PROJECTS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            if state.config.projects.isEmpty {
                Text("No projects yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.config.projects) { project in
                HStack(spacing: 6) {
                    Circle()
                        .fill(project.id == state.selectedProjectID ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(project.name)
                        .font(.callout)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture { state.selectedProjectID = project.id }
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 160, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch state.selectedTab {
        case .workspaces: workspacesStub
        case .graph: graphStub
        case .accounts: accountsStub
        }
    }

    // Plain VStack, not ScrollView: ImageRenderer does not render ScrollView
    // content offscreen; the real scrolling screen arrives in Task 19.
    private var workspacesStub: some View {
        VStack {
            VStack(alignment: .leading, spacing: 8) {
                if let snapshot = state.selectedSnapshot {
                    ForEach(snapshot.workspaces, id: \.name) { workspace in
                        workspaceStubRow(workspace)
                    }
                    if !snapshot.loose.isEmpty {
                        Text("Loose worktrees (\(snapshot.loose.count))")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                        ForEach(snapshot.loose, id: \.entry.path) { loose in
                            Text("\(loose.repo.dirName)/…/\(URL(fileURLWithPath: loose.entry.path).lastPathComponent)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if state.selectedProject == nil {
                    Text("No project selected")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No scan data yet — refresh lands in Task 17")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            Spacer(minLength: 0)
        }
    }

    private func workspaceStubRow(_ workspace: FeatureWorkspace) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color.accentColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.callout.weight(.semibold))
                Text(workspace.repos.first?.entry.branch ?? "detached")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !workspace.liveProcesses.isEmpty {
                Text("\(workspace.liveProcesses.count) live")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if !workspace.sessions.isEmpty {
                Text("\(workspace.sessions.count) session(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .glassCard()
        .padding(.leading, workspace.parentName == nil ? 0 : 24)
    }

    private var graphStub: some View {
        VStack(spacing: 8) {
            Text("Graph")
                .font(.title3.weight(.semibold))
            Text(state.graphRepoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "no repo selected")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("\(state.graphNodes.count) commits loaded — GraphScreen lands in Task 21")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .glassCard()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
    }

    private var accountsStub: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.config.accounts, id: \.name) { account in
                HStack {
                    Image(systemName: "person.crop.circle")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name).font(.callout.weight(.semibold))
                        Text(account.configDir)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
                .glassCard()
            }
            Text("AccountsScreen lands in Task 22")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var footer: some View {
        HStack {
            Text("Grove \(GroveVersion.current)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let issue = state.configIssue {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer()
            Button("Quit Grove") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
