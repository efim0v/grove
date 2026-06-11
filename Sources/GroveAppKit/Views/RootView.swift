import SwiftUI
import GroveCore

/// Panel root: sidebar of projects + tab strip + content + footer with Quit.
/// Workspaces tab renders the real WorkspacesScreen (Task 19); graph/accounts
/// stubs remain until Tasks 21/22 land GraphScreen / AccountsScreen.
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
        case .workspaces: WorkspacesScreen(state: state)
        case .graph: GraphScreen(state: state)
        case .accounts: accountsStub
        }
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
