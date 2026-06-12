import SwiftUI
import GroveCore

/// Per-project settings screen (route .projectSettings(id), spec §6.4):
/// read-only path, workspacesRoot override, branchTemplate, a default-Claude-
/// account picker, repo-aware base-branch override rows (branch picker per
/// scanned repo, "auto" = detect), the postCreateHooks dictionary with
/// add/remove rows, excludedRepos, scanDepth, and remove-project. Global
/// fields live in GlobalSettingsScreen.
///
/// DOCUMENTED DEVIATION from spec §6.4: there is no separate GLOBAL
/// default-branch-template field — ProjectConfig.branchTemplate already
/// defaults to "feat/{name}" for every new project, which covers the use
/// case without a second template layer.
struct ProjectSettingsScreen: View {
    @ObservedObject var state: AppState
    let projectID: UUID
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    @State private var newHookRepo = ""
    @State private var newHookCommand = ""
    @State private var newExcludedRepo = ""
    @State private var newSeedSource = ""
    @State private var newSeedMode: SeedMode = .symlink
    @State private var newSeedDest: SeedDest = .umbrella

    /// Always the CURRENT copy in state.config (edits replace it there).
    private var project: ProjectConfig? {
        state.config.projects.first { $0.id == projectID }
    }

    /// This project's scan snapshot — NOT selectedSnapshot, so the screen
    /// stays correct even if the selection moves underneath it.
    private var snapshot: ProjectSnapshot? {
        state.snapshots[projectID]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let project {
                if isSnapshotRender {
                    form(project)
                        .padding(12)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView {
                        form(project).padding(12)
                    }
                }
            } else {
                Text("This project is no longer configured.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // Fill the base-branch-override pickers; rows degrade to text
            // fields until then. Never runs under ImageRenderer.
            await state.loadBranches(for: snapshot?.repos ?? [])
        }
    }

    private var header: some View {
        ScopeHeader(title: "Settings", subtitle: project?.name,
                    onBack: { state.goBack() })
    }

    private func form(_ project: ProjectConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSection(title: "General") {
                LabeledRow(label: "Path") {
                    Text(project.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                LabeledRow(label: "Workspaces root") {
                    SnapshotSafeTextField(title: "default (from template)",
                                          text: workspacesRootBinding(project), monospaced: true)
                }
                LabeledRow(label: "Branch template") {
                    SnapshotSafeTextField(title: "feat/{name}",
                                          text: binding(\.branchTemplate, of: project), monospaced: true)
                }
                LabeledRow(label: "Scan depth") {
                    SnapshotSafeStepper(label: "", value: binding(\.scanDepth, of: project), range: 1...8)
                }
            }

            SettingsSection(title: "Workspaces & seeds",
                            subtitle: "files copied/symlinked into each new workspace") {
                seedFilesEditor(project)
            }

            SettingsSection(title: "Claude") {
                defaultAccountRow(project)
            }

            SettingsSection(title: "Repos") {
                baseBranchOverridesEditor(project)
                excludedReposEditor(project)
            }

            SettingsSection(title: "Hooks") {
                dictEditor(title: "Post-create hooks (zsh, run in the new worktree)",
                           dict: project.postCreateHooks,
                           keyTitle: "repo dir", valueTitle: "command",
                           newKey: $newHookRepo, newValue: $newHookCommand) { mutated in
                    var updated = project
                    updated.postCreateHooks = mutated
                    state.updateProject(updated)
                }
            }

            SettingsSection(title: "Danger") {
                Button("Remove project from Grove", role: .destructive) {
                    state.removeProject(id: project.id)
                    state.open(.projects)
                }
                .controlSize(.small)
                .help("Config only — no repos or worktrees are touched")
            }
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

    // MARK: - Default Claude account (per project)

    /// "New Claude" single-click launches on this account (spec: per-project
    /// default); "none" = nil = first configured account. The account menus
    /// everywhere still list all accounts.
    private func defaultAccountRow(_ project: ProjectConfig) -> some View {
        LabeledRow(label: "Default Claude account") {
            if isSnapshotRender {
                // Picker(.menu) renders as a yellow placeholder offscreen.
                SnapshotPickerLookalike(text: currentProject(project).defaultAccount ?? "none",
                                        monospaced: false)
            } else {
                Picker("", selection: defaultAccountBinding(project)) {
                    Text("none").tag(String?.none)
                    ForEach(state.config.accounts, id: \.name) { account in
                        Text(account.name).tag(String?.some(account.name))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            Text("single-click New Claude uses it")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func defaultAccountBinding(_ project: ProjectConfig) -> Binding<String?> {
        Binding(
            get: { currentProject(project).defaultAccount },
            set: { value in
                var current = currentProject(project)
                current.defaultAccount = value
                state.updateProject(current)
            }
        )
    }

    /// Always the CURRENT copy from state.config (the captured `project`
    /// value goes stale after any edit in the same screen session).
    private func currentProject(_ project: ProjectConfig) -> ProjectConfig {
        state.config.projects.first { $0.id == project.id } ?? project
    }

    // MARK: - Base branch overrides (repo-aware rows)

    /// One row per repo of the project's scan snapshot (plus override keys the
    /// scan does not know, so stale entries stay removable): a branch picker
    /// over the repo's local branches where "auto" removes the override
    /// (-> GitService auto-detect). Repos without a branch list (not loaded /
    /// unknown path) degrade to a snapshot-safe text field.
    private func baseBranchOverridesEditor(_ project: ProjectConfig) -> some View {
        let overrides = currentProject(project).baseBranchOverrides
        let rows = overrideEditorRows(snapshot: snapshot, overrides: overrides)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Base branch overrides (auto = detect from origin/HEAD)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(rows) { overrideRow in
                HStack(spacing: 6) {
                    Text(overrideRow.dirName)
                        .font(.system(.caption, design: .monospaced))
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    overrideControl(project: project, row: overrideRow,
                                    current: overrides[overrideRow.dirName])
                    Spacer()
                }
            }
            if rows.isEmpty {
                Text("No repos scanned yet — refresh the project first (⌘R).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func overrideControl(project: ProjectConfig, row: OverrideEditorRow,
                                 current: String?) -> some View {
        let branches = row.repoPath.flatMap { state.branchesByRepo[$0] } ?? []
        if isSnapshotRender {
            // Picker(.menu)/TextField both render as yellow placeholders
            // offscreen — one static lookalike covers either control.
            SnapshotPickerLookalike(text: current ?? "auto")
        } else if branches.isEmpty {
            SnapshotSafeTextField(title: "auto", text: overrideBinding(project, dirName: row.dirName),
                                  monospaced: true)
                .frame(width: 180)
        } else {
            Picker("", selection: overrideBinding(project, dirName: row.dirName)) {
                Text("auto").tag("")
                // An override naming a branch git no longer has still needs a
                // matching tag, or the Picker shows an empty selection.
                ForEach(current.map { startPointOptions(default: $0, branches: branches) } ?? branches,
                        id: \.self) { branch in
                    Text(branch).tag(branch)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }

    /// "" <-> no override (key removed -> auto-detect at scan/create time).
    private func overrideBinding(_ project: ProjectConfig, dirName: String) -> Binding<String> {
        Binding(
            get: { currentProject(project).baseBranchOverrides[dirName] ?? "" },
            set: { value in
                var current = currentProject(project)
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    current.baseBranchOverrides.removeValue(forKey: dirName)
                } else {
                    current.baseBranchOverrides[dirName] = trimmed
                }
                state.updateProject(current)
            }
        )
    }

    // MARK: - Dictionary editor (post-create hooks)

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

    // MARK: - Seed files

    private func seedFilesEditor(_ project: ProjectConfig) -> some View {
        let seeds = currentProject(project).seedFiles
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(seeds.enumerated()), id: \.offset) { index, seed in
                HStack(spacing: 6) {
                    Text(seed.source)
                        .font(.system(.caption, design: .monospaced))
                    Text("· \(seed.mode.rawValue) → \(seed.dest.rawValue)")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        var updated = currentProject(project)
                        updated.seedFiles.remove(at: index)
                        state.updateProject(updated)
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                }
            }
            if seeds.isEmpty {
                Text("Nothing seeded — e.g. add CLAUDE.md to share it with every workspace.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                SnapshotSafeTextField(title: "path in project (e.g. CLAUDE.md)",
                                      text: $newSeedSource, monospaced: true)
                if !isSnapshotRender {
                    Picker("", selection: $newSeedMode) {
                        Text("symlink").tag(SeedMode.symlink)
                        Text("copy").tag(SeedMode.copy)
                    }.pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
                    Picker("", selection: $newSeedDest) {
                        Text("umbrella").tag(SeedDest.umbrella)
                        Text("each repo").tag(SeedDest.eachRepo)
                    }.pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
                }
                Button("Add") {
                    let src = newSeedSource.trimmingCharacters(in: .whitespaces)
                    guard !src.isEmpty else { return }
                    var updated = currentProject(project)
                    guard !updated.seedFiles.contains(where: { $0.source == src }) else { return }
                    updated.seedFiles.append(SeedFile(source: src, mode: newSeedMode, dest: newSeedDest))
                    state.updateProject(updated)
                    newSeedSource = ""
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

}
