import SwiftUI

/// The ONE SwiftUI root for the single merged panel: the projects section
/// (`RootView`) and the usage-charts section (`ChartsSideContent`) laid out
/// side by side in an `HStack`, split by a thin internal divider (NOT a second
/// window edge), under ONE shared `NSGlassEffectView` substrate.
///
/// Equal height falls out of the `HStack` — the taller column (usually charts)
/// drives the window height; each column caps itself (`RootView`'s 560 height
/// cap, `ChartsSideContent`'s 820 cap here). When `state.showCharts` is false
/// the charts column and divider drop, so the window collapses to projects-only
/// width; the hosting controller's `preferredContentSize` shrinks and the
/// controller re-anchors the window (right edge pinned to the icon).
///
/// This is a named `View` (not an inline `HStack` in `makePanel`) so it observes
/// `state.showCharts` and is snapshot-testable.
public struct MergedRootView: View {
    @ObservedObject private var state: AppState

    public init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
    }

    public var body: some View {
        // `.top` so both sections pin their TOP edge together: the charts column is
        // usually taller (it drives the window height), so a default `.center`
        // HStack would float the shorter projects column in the vertical middle,
        // leaving bare transparent-glass bands above AND below it and dropping its
        // "Add project" top row ~25px below the charts header. Top-aligning matches
        // the menu-bar-icon anchor (top-right pinned, grows DOWN) and keeps the
        // section tops level. The projects column then stretches to the HStack
        // height so its footer toolbar (the collapse toggle) sits at the bottom
        // edge instead of floating above a gap.
        HStack(alignment: .top, spacing: 0) {
            // Projects section drives its own per-route width; stretched to the
            // (taller, charts-driven) HStack height so its footer toolbar (which
            // hosts the collapse toggle) pins to the window's bottom edge instead
            // of floating above a bare-glass band. The projects route reports a
            // *minimum* height (not a hard one) so it grows into this stretch when
            // embedded, yet still resolves to its natural size standalone/collapsed.
            RootView(state: state)
                .frame(maxHeight: .infinity, alignment: .top)
            if state.showCharts {
                // Internal divider — a thin neutral hairline, not a window edge.
                Rectangle()
                    .fill(Palette.neutral.opacity(0.18))
                    .frame(width: 1)
                // Charts section: fixed narrow width, adaptive height capped so a
                // tall charts column can't push the window off a short display
                // (replaces the old per-window screen-height cap; the controller
                // additionally clamps the final frame on-screen).
                ChartsSideContent(state: state)
                    .frame(maxHeight: 820)
            }
        }
        // The hairline edge that used to live on each of the two separate chromes
        // now wraps the single merged root, tracing the one rounded window shape.
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.panel, style: .continuous)
                .strokeBorder(.white.opacity(0.10))
        )
    }
}
