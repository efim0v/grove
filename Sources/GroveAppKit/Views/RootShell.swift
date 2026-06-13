import SwiftUI
import AppKit
import GroveCore

/// The root scope (route .projects): the project list with quick session access.
/// The usage dashboard is no longer a tab here — it lives in a permanent side
/// window (ChartsSideContent) docked left of the main panel, always visible. So
/// this shell is just the brand/limits header, the Projects content, and the
/// shared footer.
struct RootShell: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
    }

    // MARK: - Header: brand + tab strip + add (Projects only)

    private var header: some View {
        let now = Date()
        return HStack(spacing: 8) {
            Image(systemName: "tree")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Grove").font(.headline)
            // Overall remaining 5h capacity + soonest reset (item 4).
            AggregateChip(window: "5h",
                          aggregate: state.aggregateRemaining(window: .fiveHour, now: now),
                          resetsAt: state.aggregateReset(window: .fiveHour, now: now),
                          now: now)
            Spacer(minLength: 6)
            Button { addProjectViaPanel() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .help("Add a project directory")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Content (the project list; charts live in the side window)

    @ViewBuilder private var content: some View {
        ProjectsTab(state: state)
    }

    // MARK: - Footer: Accounts, settings, refresh, version, Quit

    private var footer: some View {
        HStack(spacing: 10) {
            Button { state.open(.accounts) } label: {
                Label("Accounts", systemImage: "person.2").font(.caption).fixedSize()
            }
            .buttonStyle(.plain)
            .help("Claude accounts")
            Button { state.open(.globalSettings) } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            Button {
                Task { await state.refresh() }
            } label: {
                if state.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r")
            .help("Refresh (⌘R)")
            if let issue = state.configIssue {
                Text(issue).font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text("v\(GroveVersion.current)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// NSOpenPanel is LIVE-only (it sits behind a button action, so snapshot
    /// rendering never reaches it).
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
