import SwiftUI
import AppKit
import GroveCore

/// Persistent bottom chrome for the projects COLUMN — shared by the project LIST
/// (route .projects) and the per-project tabs (route .project). It was previously
/// inlined in RootShell, so navigating into a project (.project) dropped it; now
/// RootView pins one instance below whichever of those two routes is active, so
/// the Accounts / settings / refresh / charts-collapse / version / Quit row never
/// disappears as the user moves between the list and the tabs.
///
/// The deeper scoped routes (.accounts/.globalSettings/.projectSettings/
/// .statsSettings/.createWorkspace) have their own back navigation and DON'T show
/// this footer — RootView gates that.
struct ProjectsFooter: View {
    @ObservedObject var state: AppState

    var body: some View {
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
            // Collapse / expand the side-by-side charts (account-stats) section.
            // Toggling showCharts changes MergedRootView's body → the hosting
            // controller's preferredContentSize → the window grows/shrinks from
            // the right edge (pinned to the menu-bar icon).
            Button {
                // INSTANT toggle — NO withAnimation. Animating showCharts adds/
                // removes the charts column (its NSGlassEffectView substrate) under
                // the window's glass; animating that resolve recursed Apple's Liquid
                // Glass framework to a SIGSEGV — the same crash class that
                // de-animated AppState.open()'s route swap. The window grow/shrink is
                // driven at the AppKit layer (preferredContentSize KVO →
                // applyContentSize), which resizes/re-pins without a SwiftUI animation.
                state.showCharts.toggle()
            } label: {
                Image(systemName: state.showCharts
                      ? "sidebar.right" : "chart.bar")
            }
            .buttonStyle(.plain)
            .help(state.showCharts ? "Hide charts" : "Show charts")
            if let issue = state.configIssue {
                Text(issue).font(.caption).foregroundStyle(Palette.mid).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text("v\(GroveVersion.current)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            // Rounded/capsule affordance (macOS-26): a pill, not a default
            // rectangular push button.
            Button { NSApp.terminate(nil) } label: {
                Text("Quit")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .background(.white.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .keyboardShortcut("q")
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
