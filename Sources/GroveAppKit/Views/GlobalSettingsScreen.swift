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
    /// Persisted window-substrate selection (Liquid Glass default ⇄ Visual Effect).
    /// Writing it posts `.groveSubstrateStyleChanged`, which the menu-bar controller
    /// observes to live-swap the panel backing without a relaunch.
    @AppStorage(WindowSubstrateStyle.defaultsKey)
    private var substrateRaw = WindowSubstrateStyle.liquidGlass.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
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
                    aggregate: state.aggregateRemaining(window: .fiveHour, now: Date()),
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
            SettingsSection(title: "Transcript safety-net") {
                transcriptMirrorSection
            }
            SettingsSection(title: "Window substrate") {
                if isSnapshotRender {
                    SnapshotPickerLookalike(text: currentSubstrate.label, monospaced: false)
                } else {
                    Picker("", selection: substrateBinding) {
                        ForEach(WindowSubstrateStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Text("Liquid Glass is the default. Visual Effect uses an always-active, "
                     + "behind-window NSVisualEffectView substrate; switches live.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Transcript safety-net section

    private var transcriptMirrorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledRow(label: "Enabled") {
                if isSnapshotRender {
                    Text(state.config.transcriptMirror.enabled ? "on" : "off")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Toggle("Keep a backup of every session",
                           isOn: transcriptMirrorEnabledBinding)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                }
            }
            LabeledRow(label: "Keep for (days)") {
                SnapshotSafeStepper(label: "", value: transcriptMirrorMaxDaysBinding, range: 1...365)
            }
            LabeledRow(label: "Max mirror size (MB)") {
                SnapshotSafeStepper(label: "", value: transcriptMirrorMaxMBBinding, range: 10...10000)
            }
            Text("Grove hardlink-mirrors every session transcript and auto-restores deleted files.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var transcriptMirrorEnabledBinding: Binding<Bool> {
        Binding(
            get: { state.config.transcriptMirror.enabled },
            set: { value in
                var settings = state.config.transcriptMirror
                settings.enabled = value
                state.setTranscriptMirror(settings)
            }
        )
    }

    private var transcriptMirrorMaxDaysBinding: Binding<Int> {
        Binding(
            get: { state.config.transcriptMirror.maxDays },
            set: { value in
                var settings = state.config.transcriptMirror
                settings.maxDays = value
                state.setTranscriptMirror(settings)
            }
        )
    }

    private var transcriptMirrorMaxMBBinding: Binding<Int> {
        Binding(
            get: { state.config.transcriptMirror.maxMB },
            set: { value in
                var settings = state.config.transcriptMirror
                settings.maxMB = value
                state.setTranscriptMirror(settings)
            }
        )
    }

    // MARK: - Window substrate toggle

    private var currentSubstrate: WindowSubstrateStyle {
        WindowSubstrateStyle(rawValue: substrateRaw) ?? .liquidGlass
    }

    private var substrateBinding: Binding<WindowSubstrateStyle> {
        Binding(get: { currentSubstrate },
                set: { newValue in
                    substrateRaw = newValue.rawValue
                    NotificationCenter.default.post(name: .groveSubstrateStyleChanged, object: nil)
                })
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
