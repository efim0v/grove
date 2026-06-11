import SwiftUI
import GroveCore

/// Workspace creation screen (spec §5.4/§6.1) — a full-screen panel state
/// (route .createWorkspace), never an overlay: name with validation feedback,
/// branch live-preview from the project's branchTemplate, repo checkboxes
/// (default all), fork-from picker (base or an existing workspace) with
/// per-repo start-point captions, async creation with an auto-scrolling
/// progress log, and a strictly-scoped rollback offer on failure.
struct CreateWorkspaceScreen: View {
    @ObservedObject var state: AppState
    let prefill: CreatePrefill
    /// Explicit close callback (RootView passes state.goBack()): the screen
    /// is a route of the single panel window, so @Environment(\.dismiss)
    /// would be a no-op.
    let onClose: () -> Void
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    private enum Phase: Equatable {
        case editing
        case running
        case succeeded
        case failed(String)
        case rolledBack
    }

    @State private var name: String
    /// nil -> the branch field shows branchPreview(template, name) live;
    /// set on first manual edit and sticks until the reset button.
    @State private var branchOverride: String?
    @State private var forkFromName: String?
    @State private var selectedRepoPaths: Set<String>
    /// Explicit per-repo start-point picks (key = repo.path). Absent = follow
    /// the resolved default (startPointCaption). Only picks that differ from
    /// the default become startPointOverrides at create time.
    @State private var startPointSelections: [String: String] = [:]
    @State private var phase: Phase = .editing
    @State private var logLines: [String] = []
    @State private var report: CreationReport?

    @MainActor
    init(state: AppState, prefill: CreatePrefill, onClose: @escaping () -> Void) {
        _state = ObservedObject(wrappedValue: state)
        self.prefill = prefill
        self.onClose = onClose
        _name = State(initialValue: prefill.name)
        _branchOverride = State(initialValue: prefill.branch)
        _forkFromName = State(initialValue: prefill.forkFrom?.name)
        let repos = state.selectedSnapshot?.repos ?? []
        _selectedRepoPaths = State(initialValue: Set(repos.map(\.path)))   // default: all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let snapshot = state.selectedSnapshot {
                form(snapshot: snapshot)
            } else {
                Text("No project selected.")
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
        }
        // Width comes from RootView's route frame (540); height is adaptive —
        // fixedSize keeps the form's natural height (RootView caps it at 560).
        .fixedSize(horizontal: false, vertical: true)
        .task {
            // Fill the per-repo branch pickers; until this lands they show
            // just the resolved default. Never runs under ImageRenderer.
            await state.loadBranches(for: state.selectedSnapshot?.repos ?? [])
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                onClose()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(phase == .running)
            .help("Back")
            Text("New Workspace")
                .font(.headline)
            Spacer()
        }
        .padding(12)
    }

    private func form(snapshot: ProjectSnapshot) -> some View {
        let template = snapshot.project.branchTemplate
        let branch = branchOverride ?? branchPreview(template: template, name: name)
        let forkFrom = snapshot.workspaces.first { $0.name == forkFromName }
        return VStack(alignment: .leading, spacing: 12) {
            Group {
                nameField
                branchField(template: template, branch: branch)
                forkFromPicker(snapshot: snapshot)
                repoList(snapshot: snapshot, forkFrom: forkFrom)
            }
            .disabled(phase != .editing)
            progressAndLog
            footer(branch: branch, snapshot: snapshot, forkFrom: forkFrom)
        }
        .padding(12)
    }

    // MARK: - Name + validation feedback

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 3) {
            SnapshotSafeTextField(title: "Workspace name", text: $name)
            if let issue = workspaceNameIssue(name), !name.isEmpty {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Branch with live template preview

    private func branchField(template: String, branch: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                SnapshotSafeTextField(title: "Branch", text: Binding(
                    get: { branch },
                    set: { branchOverride = $0 }
                ), monospaced: true)
                if branchOverride != nil {
                    Button {
                        branchOverride = nil
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Follow the template preview again")
                }
            }
            Text("template: \(template)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Fork from: base (default) or an existing workspace

    private func forkFromPicker(snapshot: ProjectSnapshot) -> some View {
        // Picker(.menu) is AppKit-backed and renders as an error placeholder
        // under ImageRenderer — snapshot mode shows a static lookalike instead.
        HStack(spacing: 6) {
            Text("Fork from")
            if isSnapshotRender {
                Text(forkFromName.map { "workspace \($0)" }
                     ?? prefill.base.map { "branch \($0)" } ?? "base branches")
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.2)))
            } else {
                Picker("", selection: $forkFromName) {
                    Text(prefill.base.map { "branch \($0)" } ?? "base branches")
                        .tag(String?.none)
                    ForEach(snapshot.workspaces, id: \.name) { workspace in
                        Text("workspace \(workspace.name)").tag(String?.some(workspace.name))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    // MARK: - Repo checkboxes with per-repo start-point pickers

    private func repoList(snapshot: ProjectSnapshot, forkFrom: FeatureWorkspace?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Repos")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            // Pure-SwiftUI checkbox row: Toggle(.checkbox) is AppKit-backed and
            // renders as an error placeholder under ImageRenderer. The branch
            // picker sits OUTSIDE the toggle button so clicking it never
            // flips the checkbox.
            ForEach(snapshot.repos.sorted { $0.dirName < $1.dirName }, id: \.path) { repo in
                let isOn = repoBinding(repo)
                HStack(spacing: 6) {
                    Button {
                        isOn.wrappedValue.toggle()
                    } label: {
                        HStack {
                            Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
                            Text(repo.dirName)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Text("from")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    startPointSelector(repo: repo, forkFrom: forkFrom, snapshot: snapshot)
                }
            }
            if snapshot.repos.isEmpty {
                Text("No repos found in this project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Per-repo start-point control replacing the old static caption: a menu
    /// Picker over the repo's local branches (resolved default preselected and
    /// prepended when unlisted; not-yet-loaded lists degrade to just the
    /// default). Picker(.menu) is AppKit-backed and renders as a yellow error
    /// placeholder under ImageRenderer, so snapshot mode shows a static
    /// lookalike with the same resolved value.
    @ViewBuilder
    private func startPointSelector(repo: RepoInfo, forkFrom: FeatureWorkspace?,
                                    snapshot: ProjectSnapshot) -> some View {
        let resolved = startPointCaption(repo: repo, forkFrom: forkFrom,
                                         base: prefill.base, snapshot: snapshot)
        if isSnapshotRender {
            SnapshotPickerLookalike(text: startPointSelections[repo.path] ?? resolved)
        } else {
            Picker("", selection: startPointBinding(repo: repo, resolved: resolved)) {
                ForEach(startPointOptions(default: resolved,
                                          branches: state.branchesByRepo[repo.path] ?? []),
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

    private func startPointBinding(repo: RepoInfo, resolved: String) -> Binding<String> {
        Binding(
            get: { startPointSelections[repo.path] ?? resolved },
            set: { startPointSelections[repo.path] = $0 }
        )
    }

    private func repoBinding(_ repo: RepoInfo) -> Binding<Bool> {
        Binding(
            get: { selectedRepoPaths.contains(repo.path) },
            set: { isOn in
                if isOn {
                    selectedRepoPaths.insert(repo.path)
                } else {
                    selectedRepoPaths.remove(repo.path)
                }
            }
        )
    }

    // MARK: - Progress, log, failure banner

    @ViewBuilder private var progressAndLog: some View {
        if phase == .running {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Creating workspace…")
                    .font(.caption)
            }
        }
        if !logLines.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 120)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: logLines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        if case .failed(let message) = phase {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if phase == .rolledBack {
            Label("Rolled back this run's artifacts.", systemImage: "arrow.uturn.backward.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer buttons per phase

    private func footer(branch: String, snapshot: ProjectSnapshot, forkFrom: FeatureWorkspace?) -> some View {
        HStack(spacing: 8) {
            Spacer()
            switch phase {
            case .editing, .running:
                Button("Cancel") { onClose() }
                    .disabled(phase == .running)
                Button("Create") { create(snapshot: snapshot, branch: branch, forkFrom: forkFrom) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate(branch: branch))
            case .succeeded:
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Button("Keep as is") { onClose() }
                Button("Roll back created artifacts", role: .destructive) { rollback() }
                    .disabled((report?.artifacts.isEmpty) ?? true)
            case .rolledBack:
                Button("Close") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func canCreate(branch: String) -> Bool {
        workspaceNameIssue(name) == nil
            && !branch.trimmingCharacters(in: .whitespaces).isEmpty
            && !selectedRepoPaths.isEmpty
            && phase == .editing
    }

    // MARK: - Actions

    private func create(snapshot: ProjectSnapshot, branch: String, forkFrom: FeatureWorkspace?) {
        let repos = snapshot.repos
            .filter { selectedRepoPaths.contains($0.path) }
            .sorted { $0.dirName < $1.dirName }
        // Only picks that differ from each repo's resolved default become
        // overrides — default picks keep creation's normal resolution.
        let overrides = resolvedStartPointOverrides(repos: repos,
                                                    selections: startPointSelections,
                                                    forkFrom: forkFrom, base: prefill.base,
                                                    snapshot: snapshot)
        phase = .running
        logLines = ["creating \(name) on \(branch) in \(repos.count) repo(s)…"]
        Task {
            let result = await state.createWorkspace(name: name, branch: branch,
                                                     repos: repos, forkFrom: forkFrom,
                                                     startPointOverrides: overrides)
            if let result {
                report = result
                logLines += result.logLines
                if let failure = result.failure {
                    phase = .failed(failure)
                } else {
                    logLines.append("done: \(result.artifacts.count) worktree(s) created")
                    phase = .succeeded
                    await state.refresh()
                }
            } else {
                phase = .failed(state.actionError ?? "Creation failed.")
            }
        }
    }

    /// The ONLY destructive operation in v1, strictly scoped to the artifacts
    /// of this creation run (spec §5.4).
    private func rollback() {
        guard let artifacts = report?.artifacts, !artifacts.isEmpty else { return }
        phase = .running
        Task {
            let lines = await state.rollback(artifacts)
            logLines += lines
            phase = .rolledBack
            await state.refresh()
        }
    }
}
