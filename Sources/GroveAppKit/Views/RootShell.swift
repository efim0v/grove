import SwiftUI
import AppKit
import GroveCore

/// The root scope (route .projects): the project list with quick session access.
/// The usage dashboard is no longer a tab here — it's the embedded charts section
/// (ChartsSideContent) of the merged window, shown to the RIGHT of this shell in
/// MergedRootView's HStack whenever `state.showCharts` is true. So this shell is
/// just the add-project row and the Projects content. The footer (Accounts ·
/// settings · refresh · charts-collapse · version · Quit) is now SHARED chrome
/// hoisted into RootView's `ProjectsFooter`, pinned below BOTH this list and the
/// per-project tabs so it never disappears when the user drills into a project.
struct RootShell: View {
    @ObservedObject var state: AppState
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    var body: some View {
        VStack(spacing: 0) {
            addRow
            // Fill DOWN to the shared footer (pinned by RootView) so the list
            // scroll area reaches just above it — no bare-glass gap above the
            // bottom edge.
            content
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Add row (the header is gone — the limits live in the charts section).

    /// A simple accent text-button row at the top, in the projects' own style —
    /// no brand, no limits chip (those now live in the embedded charts section).
    private var addRow: some View {
        HStack(spacing: 0) {
            Button { addProjectViaPanel() } label: {
                Label("Add project", systemImage: "plus")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(cardAccent)
            }
            .buttonStyle(.plain)
            .help("Add a project directory")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Content (the project list; charts live in the embedded charts section)

    @ViewBuilder private var content: some View {
        ProjectsTab(state: state)
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
