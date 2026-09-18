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
    /// Measured natural height of the usage (charts) column. The window is capped to
    /// THIS when the charts are shown, so a tall project scrolls instead of growing
    /// the window past the usage panel (the user's request). 0 until first measured.
    @State private var chartsHeight: CGFloat = 0

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
            // Projects section. Capped to the usage panel's height when the charts are
            // shown, so a tall project (long sessions/worktrees list) SCROLLS inside the
            // per-tab ScrollViews instead of growing the window past the usage panel
            // (the NSHostingController otherwise auto-grows the WINDOW to fit this view's
            // ideal height, bypassing the AppKit-side caps). Falls back to the screen
            // height when the charts are hidden.
            RootView(state: state)
                .frame(maxHeight: projectsCap, alignment: .top)
            if state.showCharts {
                chartsColumn
            }
        }
        // The hairline edge that used to live on each of the two separate chromes
        // now wraps the single merged root, tracing the one rounded window shape.
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.panel, style: .continuous)
                .strokeBorder(.white.opacity(0.10))
        )
        // Safety net: never exceed the screen even if the measured charts height is
        // stale/huge for a frame.
        .frame(maxHeight: Self.maxRootHeight, alignment: .top)
        .onPreferenceChange(ChartsHeightKey.self) { h in
            if h > 1, abs(h - chartsHeight) > 0.5 { chartsHeight = h }
        }
    }

    /// The usage (charts) column — a CLEAR Liquid-Glass block holding the cards. NO
    /// "Usage" header (the cards are self-evidently usage). Its NATURAL height (not
    /// stretched) defines the window height; a GeometryReader reports it so the
    /// projects column can match it.
    private var chartsColumn: some View {
        GlassMenuContainer {
            ChartsSideContent(state: state)
                .padding(7)
                // Measured on the CARDS, before the block below is stretched: measuring
                // the stretched container would feed `projectsCap` back into its own
                // input. The outer vertical padding isn't inside this subtree, so it's
                // added from the same constants the paddings use.
                .background(GeometryReader { g in
                    Color.clear.preference(key: ChartsHeightKey.self,
                                           value: g.size.height + Self.chartsVerticalChrome)
                })
                // Cards pinned to the TOP of the block; the block itself fills the
                // window height, so it never floats over a bare-glass band when the
                // projects column turns out to be taller.
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: 820)
        .padding(.trailing, 8)
        .padding(.top, Self.chartsTopPad)
        .padding(.bottom, Self.chartsBottomPad)
    }

    private static let chartsTopPad: CGFloat = 14
    private static let chartsBottomPad: CGFloat = 8
    /// Vertical chrome outside the measured subtree, added back to the reported height.
    private static var chartsVerticalChrome: CGFloat { chartsTopPad + chartsBottomPad }

    /// Height cap for the projects column: the usage panel's height when shown (so the
    /// window never exceeds it), else the screen height.
    private var projectsCap: CGFloat {
        state.showCharts && chartsHeight > 1 ? chartsHeight : Self.maxRootHeight
    }

    /// The tallest the merged root may be: the main screen's visible height (minus a
    /// small margin), so the window can't grow off-screen. Read at render time; a
    /// stale value after a display change self-corrects on the next render.
    static var maxRootHeight: CGFloat {
        max(320, (NSScreen.main?.visibleFrame.height ?? 1200) - 8)
    }
}

/// Reports the usage (charts) column's natural height up to MergedRootView so the
/// projects column can be capped to it.
private struct ChartsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
