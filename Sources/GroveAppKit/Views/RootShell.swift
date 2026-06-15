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

    /// Live vertical content offset of the project list, pushed up from
    /// ProjectsTab's ScrollView via `.tracksScrollOffset`. Drives the floating
    /// large-title collapse. Stays 0 offscreen (snapshots never scroll) → the
    /// header renders at its full at-rest size.
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            projectsTitle
            addRow
            // Fill DOWN to the shared footer (pinned by RootView) so the list
            // scroll area reaches just above it — no bare-glass gap above the
            // bottom edge.
            content
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Floating large title ("Projects", iOS large-title collapse)

    /// 0…1 collapse fraction over the first 44pt of upward scroll. 0 at rest
    /// (and always offscreen) → full large title; 1 once scrolled past 44pt.
    private var collapse: CGFloat { min(1, max(0, scrollOffset / 44)) }
    /// largeTitle → ~callout size as the list scrolls up.
    private var titleScale: CGFloat { 1 - 0.45 * collapse }
    /// Fades fully out by the end of the collapse.
    private var titleOpacity: CGFloat { 1 - collapse }

    /// The H1. A 44pt header band that collapses to 0 as the user scrolls up
    /// (true iOS large-title slide-under), with the title scaling down and
    /// fading. At rest (`collapse == 0`, and always in snapshots) it's the full
    /// 44pt band with the full-size bold large title.
    private var projectsTitle: some View {
        Text("Projects")
            .font(.largeTitle.weight(.bold))
            .scaleEffect(titleScale, anchor: .bottomLeading)
            .opacity(titleOpacity)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 44 * (1 - collapse), alignment: .bottomLeading)
            .clipped()
            .padding(.horizontal, 16)
            .padding(.top, collapse < 1 ? 14 : 0)
            .allowsHitTesting(false)
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
        ProjectsTab(state: state, scrollOffset: $scrollOffset)
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

/// Pushes the enclosing ScrollView's vertical content offset up to a binding,
/// reusing the same macOS-26 `onScrollGeometryChange` primitive the collapsible
/// search row uses (SearchCollapseOnScroll). Where the search version fires a
/// closure, this one writes the (clamped, non-negative) offset so RootShell can
/// drive its floating large-title collapse. Inert offscreen: snapshots never
/// scroll → the offset stays 0 → the title renders at its full at-rest size.
private struct TrackScrollOffset: ViewModifier {
    @Binding var offset: CGFloat

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newOffset in
            let clamped = max(0, newOffset)
            if abs(clamped - offset) > 0.5 { offset = clamped }
        }
    }
}

extension View {
    /// Mirrors the scrolled content's vertical offset into `offset` so an
    /// enclosing view (RootShell) can drive a floating header. Attach INSIDE a
    /// `ScrollView`'s content, like `.collapsesSearchOnScroll()`.
    func tracksScrollOffset(_ offset: Binding<CGFloat>) -> some View {
        modifier(TrackScrollOffset(offset: offset))
    }
}
