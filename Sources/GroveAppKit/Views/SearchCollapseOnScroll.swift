import SwiftUI

/// Hide-on-scroll plumbing for the collapsible search row (ProjectScreen).
///
/// The search row lives in ProjectScreen, but the scrollable list lives DOWN in
/// each tab screen (Workspaces / Graph / Stats / Sessions), so the tab needs a
/// way to tell the row "the user scrolled — collapse back to the magnifier".
/// ProjectScreen injects a closure here; each tab's LIVE `ScrollView` attaches
/// `.collapsesSearchOnScroll()`, which uses the native `onScrollGeometryChange`
/// primitive (macOS 15+) to call the closure when the vertical content offset
/// moves. Snapshots never scroll, so this is inert offscreen.
struct CollapseSearchOnScrollKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Set by ProjectScreen; invoked by a scrolled tab to collapse the search row.
    var collapseSearchOnScroll: (() -> Void)? {
        get { self[CollapseSearchOnScrollKey.self] }
        set { self[CollapseSearchOnScrollKey.self] = newValue }
    }
}

/// Attach INSIDE a `ScrollView`'s content (so it observes the enclosing scroll
/// view's geometry). When the vertical content offset changes — i.e. the user
/// scrolls the list — it fires the environment's `collapseSearchOnScroll`, which
/// re-collapses ProjectScreen's floating search to the bare magnifier. ⌘F / a tap
/// re-expand it as before.
private struct CollapseSearchOnScroll: ViewModifier {
    @Environment(\.collapseSearchOnScroll) private var collapse

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { oldOffset, newOffset in
            // Any real scroll movement (not a sub-pixel relayout jitter) collapses
            // the search. Both directions count: the user is interacting with the
            // list, so the floating field should get out of the way.
            if abs(newOffset - oldOffset) > 1 {
                collapse?()
            }
        }
    }
}

extension View {
    /// Collapses ProjectScreen's floating search row when this scroll content moves.
    func collapsesSearchOnScroll() -> some View {
        modifier(CollapseSearchOnScroll())
    }
}
