import SwiftUI
import AppKit
import GroveCore

/// Settings sheet (spec §6.4). Global: the workspaces-root template.
/// Per selected project: read-only path, workspacesRoot override,
/// branchTemplate, baseBranchOverrides and postCreateHooks dictionaries with
/// add/remove rows, excludedRepos, scanDepth. Add project = NSOpenPanel
/// (live interaction only — never constructed during snapshot rendering).
///
/// DOCUMENTED DEVIATION from spec §6.4: there is no separate GLOBAL
/// default-branch-template field — ProjectConfig.branchTemplate already
/// defaults to "feat/{name}" for every new project, which covers the use
/// case without a second template layer.
struct SettingsSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    @State private var newOverrideRepo = ""
    @State private var newOverrideBranch = ""
    @State private var newHookRepo = ""
    @State private var newHookCommand = ""
    @State private var newExcludedRepo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isSnapshotRender {
                form.padding(12)
            } else {
                ScrollView {
                    form.padding(12)
                }
                .frame(maxHeight: 440)
            }
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            globalSection
            Divider()
            if let project = state.selectedProject {
                projectSection(project)
            } else {
                Text("No project selected — add one below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Divider()
            projectListActions
        }
    }

    // MARK: - Global

    private var globalSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Global")
            HStack(spacing: 8) {
                Text("Workspaces root template")
                    .font(.callout)
                SnapshotSafeTextField(title: "~/Workspaces/{project}",
                                      text: rootTemplateBinding, monospaced: true)
            }
            Text("{project} is replaced by the project name; per-project override below wins.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var rootTemplateBinding: Binding<String> {
        Binding(get: { state.config.workspacesRootTemplate },
                set: { state.setWorkspacesRootTemplate($0) })
    }

    // MARK: - Selected project

    private func projectSection(_ project: ProjectConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Project: \(project.name)")

            row("Path") {
                Text(project.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            row("Workspaces root") {
                SnapshotSafeTextField(title: "default (from template)",
                                      text: workspacesRootBinding(project), monospaced: true)
            }
            row("Branch template") {
                SnapshotSafeTextField(title: "feat/{name}",
                                      text: binding(\.branchTemplate, of: project),
                                      monospaced: true)
            }

            dictEditor(title: "Base branch overrides",
                       dict: project.baseBranchOverrides,
                       keyTitle: "repo dir", valueTitle: "branch",
                       newKey: $newOverrideRepo, newValue: $newOverrideBranch) { mutated in
                var updated = project
                updated.baseBranchOverrides = mutated
                state.updateProject(updated)
            }

            dictEditor(title: "Post-create hooks (zsh, run in the new worktree)",
                       dict: project.postCreateHooks,
                       keyTitle: "repo dir", valueTitle: "command",
                       newKey: $newHookRepo, newValue: $newHookCommand) { mutated in
                var updated = project
                updated.postCreateHooks = mutated
                state.updateProject(updated)
            }

            excludedReposEditor(project)

            SnapshotSafeStepper(label: "Scan depth",
                                value: binding(\.scanDepth, of: project),
                                range: 1...8)

            Button("Remove project from Grove", role: .destructive) {
                state.removeProject(id: project.id)
            }
            .controlSize(.small)
            .help("Config only — no repos or worktrees are touched")
        }
    }

    /// Read-through binding: always edits the CURRENT copy in state.config
    /// and persists via updateProject.
    private func binding<T>(_ keyPath: WritableKeyPath<ProjectConfig, T>,
                            of project: ProjectConfig) -> Binding<T> {
        Binding(
            get: {
                (state.config.projects.first { $0.id == project.id } ?? project)[keyPath: keyPath]
            },
            set: { value in
                guard var current = state.config.projects.first(where: { $0.id == project.id })
                else { return }
                current[keyPath: keyPath] = value
                state.updateProject(current)
            }
        )
    }

    /// Optional workspacesRoot mapped to a text field: empty string <-> nil
    /// (nil = derive from the global template).
    private func workspacesRootBinding(_ project: ProjectConfig) -> Binding<String> {
        Binding(
            get: { (state.config.projects.first { $0.id == project.id })?.workspacesRoot ?? "" },
            set: { value in
                guard var current = state.config.projects.first(where: { $0.id == project.id })
                else { return }
                current.workspacesRoot = value.isEmpty ? nil : value
                state.updateProject(current)
            }
        )
    }

    // MARK: - Dictionary editor (overrides / hooks)

    private func dictEditor(title: String, dict: [String: String],
                            keyTitle: String, valueTitle: String,
                            newKey: Binding<String>, newValue: Binding<String>,
                            commit: @escaping ([String: String]) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(dict.keys.sorted(), id: \.self) { key in
                HStack(spacing: 6) {
                    Text(key)
                        .font(.system(.caption, design: .monospaced))
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(dict[key] ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        var mutated = dict
                        mutated.removeValue(forKey: key)
                        commit(mutated)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                SnapshotSafeTextField(title: keyTitle, text: newKey, monospaced: true)
                    .frame(width: 160)
                SnapshotSafeTextField(title: valueTitle, text: newValue, monospaced: true)
                Button("Add") {
                    let key = newKey.wrappedValue.trimmingCharacters(in: .whitespaces)
                    let value = newValue.wrappedValue.trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty, !value.isEmpty else { return }
                    var mutated = dict
                    mutated[key] = value
                    commit(mutated)
                    newKey.wrappedValue = ""
                    newValue.wrappedValue = ""
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Excluded repos

    private func excludedReposEditor(_ project: ProjectConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Excluded repos")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(project.excludedRepos, id: \.self) { name in
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Button {
                        var updated = project
                        updated.excludedRepos.removeAll { $0 == name }
                        state.updateProject(updated)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                SnapshotSafeTextField(title: "repo dir name", text: $newExcludedRepo,
                                      monospaced: true)
                    .frame(width: 200)
                Button("Add") {
                    let name = newExcludedRepo.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, !project.excludedRepos.contains(name) else { return }
                    var updated = project
                    updated.excludedRepos.append(name)
                    state.updateProject(updated)
                    newExcludedRepo = ""
                }
                .controlSize(.small)
                Spacer()
            }
        }
    }

    // MARK: - Project list actions

    private var projectListActions: some View {
        HStack(spacing: 8) {
            Button {
                addProjectViaPanel()
            } label: {
                Label("Add project…", systemImage: "plus")
            }
            Text("pick the project directory that contains your repos")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
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

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .frame(width: 130, alignment: .leading)
            content()
        }
    }
}
