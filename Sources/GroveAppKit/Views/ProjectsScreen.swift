import SwiftUI
import AppKit
import GroveCore

/// Root scope (route .projects): one card per configured project — name, path
/// caption, repo/workspace counts when a scan snapshot is loaded, chevron —
/// tap opens that project's scope. Header has the add-project (+) button
/// (NSOpenPanel, live only); the footer routes to Accounts and global
/// Settings, refreshes, and quits.
struct ProjectsScreen: View {
    @ObservedObject var state: AppState
    /// ImageRenderer does not render ScrollView content offscreen, so snapshot
    /// mode swaps the card list container to a plain stack.
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
    }

    // MARK: - Header: brand + add project

    private var header: some View {
        HStack(spacing: 10) {
            Label("Grove", systemImage: "tree")
                .font(.headline)
            Spacer()
            Button {
                addProjectViaPanel()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("Add a project directory")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Project cards

    @ViewBuilder private var list: some View {
        if state.config.projects.isEmpty {
            emptyState
        } else if isSnapshotRender {
            cards
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                cards
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var cards: some View {
        VStack(spacing: 8) {
            ForEach(state.config.projects) { project in
                projectCard(project)
            }
        }
        .padding(12)
    }

    private func projectCard(_ project: ProjectConfig) -> some View {
        Button {
            state.open(.project(project.id))
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(project.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 10)
                if let snapshot = state.snapshots[project.id] {
                    Text("\(snapshot.repos.count) repos · \(snapshot.workspaces.count) workspaces")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard()
        .help(project.path)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tree")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No projects yet")
                .font(.headline)
            Text("Add the directory that contains your repos with +.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer: Accounts, global settings, refresh, version, Quit

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                state.open(.accounts)
            } label: {
                Label("Accounts", systemImage: "person.2")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .help("Claude accounts")
            Button {
                state.open(.globalSettings)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            Button {
                Task { await state.refresh() }
            } label: {
                if state.isScanning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r")
            .help("Rescan the selected project (⌘R)")
            if let issue = state.configIssue {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer()
            Text("Grove \(GroveVersion.current)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
