import SwiftUI
import AppKit
import GroveCore

/// Global settings screen (route .globalSettings): the workspaces-root
/// template plus the project list (add via NSOpenPanel — live interaction
/// only, never constructed during snapshot rendering — and config-only
/// remove). Per-project fields live in ProjectSettingsScreen.
struct GlobalSettingsScreen: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isSnapshotRender {
                form
                    .padding(12)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    form.padding(12)
                }
            }
        }
    }

    private var header: some View {
        ScopeHeader(title: "Settings", subtitle: "global",
                    onBack: { state.goBack() })
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSection(title: "Workspaces") {
                SnapshotSafeTextField(title: "~/Workspaces/{project}",
                                      text: rootTemplateBinding, monospaced: true)
                Text("{project} is replaced by the project name; a per-project override wins.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            SettingsSection(title: "Projects") {
                projectsList
            }
        }
    }

    // MARK: - Workspaces root template

    private var rootTemplateBinding: Binding<String> {
        Binding(get: { state.config.workspacesRootTemplate },
                set: { state.setWorkspacesRootTemplate($0) })
    }

    // MARK: - Projects list (add / remove)

    private var projectsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.config.projects.isEmpty {
                Text("No projects yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.config.projects) { project in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                            .font(.callout)
                        Text(project.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        state.removeProject(id: project.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Config only — no repos or worktrees are touched")
                }
            }
            HStack(spacing: 8) {
                Button {
                    addProjectViaPanel()
                } label: {
                    Label("Add project…", systemImage: "plus")
                }
                Text("pick the directory that contains your repos")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    /// NSOpenPanel is LIVE-only: it sits behind a button action, so snapshot
    /// rendering (which never dispatches actions) cannot reach it.
    private func addProjectViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        if panel.runModal() == .OK, let url = panel.url {
            state.addProject(at: url.path)
        }
    }
}
