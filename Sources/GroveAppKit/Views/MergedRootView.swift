import SwiftUI

/// The ONE SwiftUI root for the single merged panel: the projects section
/// (`RootView`) and the usage-charts section (`ChartsSideContent`) laid out
/// side by side in an `HStack` as two macOS-26 grouped BLOCKS — gap-separated,
/// NOT joined by a flat divider — under ONE shared `NSGlassEffectView` substrate.
///
/// Equal height falls out of the `HStack` — the taller column (usually charts)
/// drives the window height; each column caps itself (`RootView`'s 560 height
/// cap, `ChartsSideContent`'s 820 cap here). When `state.showCharts` is false
/// the charts block drops, so the window collapses to projects-only width; the
/// hosting controller's `preferredContentSize` shrinks and the controller
/// re-anchors the window (right edge pinned to the icon).
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
        //
        // macOS-26 grouped blocks: the projects column and the charts column read
        // as two distinct floating BLOCKS gap-separated by `spacing` — NOT joined
        // by a flat hairline divider (which read as old-style chrome). The single
        // window glass substrate still sits under BOTH.
        HStack(alignment: .top, spacing: 8) {
            // Projects section drives its own per-route width; stretched to the
            // (taller, charts-driven) HStack height so its footer toolbar (which
            // hosts the collapse toggle) pins to the window's bottom edge instead
            // of floating above a bare-glass band. The projects route reports a
            // *minimum* height (not a hard one) so it grows into this stretch when
            // embedded, yet still resolves to its natural size standalone/collapsed.
            RootView(state: state)
                .frame(maxHeight: .infinity, alignment: .top)
            if state.showCharts {
                // Charts section: fixed narrow width, adaptive height capped so a
                // tall charts column can't push the window off a short display
                // (replaces the old per-window screen-height cap; the controller
                // additionally clamps the final frame on-screen). Wrapped in a
                // CLEAR Liquid-Glass "menu block" (GlassMenuContainer, a native
                // NSGlassEffectView backdrop) — NOT the gray .glassCard — so it
                // reads as a distinct floating glass layer and the inner gray
                // content cards (DashboardScreen's GlassCards) stand out against
                // it. Separation from the projects column is the HStack `spacing`
                // gap, not a hairline divider.
                //
                // The 8pt OUTER inset (trailing + vertical) floats the glass
                // block clear of the window's rounded corners — mirroring the
                // footer block's outer inset in RootView so the two menu blocks
                // are symmetric vs. the window edge (otherwise the block's tighter
                // card radius sits inside the window's wider panel radius and
                // leaves a sliver of substrate at the corners). The leading edge
                // takes no inset: the HStack `spacing: 8` already gaps it from the
                // projects column. The inner `.padding(8)` is the content padding
                // INSIDE the glass.
                GlassMenuContainer {
                    ChartsSideContent(state: state)
                        // SINGLE ~7pt inner content inset from the clear-block edge
                        // to the graph cards (was a doubled 16pt: 8 here + 8 in
                        // DashboardScreen, now zeroed). Halved so the cards sit close
                        // to the block edge, top and bottom — no giant inner gap.
                        .padding(7)
                        // Pin the cards to the TOP and let the clear glass block
                        // STRETCH to fill the (taller) HStack height, so the block's
                        // bottom rim reaches the footer block's bottom rim instead of
                        // hugging the cards and leaving a bare-glass band below.
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(maxHeight: 820)
                .padding(.trailing, 8)
                // Top outer inset aligns the charts block's top rim with the TOP of
                // the left content (the "Projects" header band, whose own top inset
                // is 14); the bottom inset (8) matches the footer block's bottom
                // inset so the charts block bottom aligns with the footer bottom.
                .padding(.top, 14)
                .padding(.bottom, 8)
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
