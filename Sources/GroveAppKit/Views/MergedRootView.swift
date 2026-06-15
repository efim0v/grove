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
                // Charts section: its own floating "Usage" H1 (mirroring the left
                // "Projects" large title) above a CLEAR Liquid-Glass "menu block"
                // (GlassMenuContainer) holding the cards. The title floats on the
                // bare window glass — exactly like "Projects" floats above the
                // project list — so the two section titles share ONE baseline
                // across the window (both columns top-align to the HStack top, both
                // bands are 44pt with a 14pt top inset → aligned by construction).
                // The glass block reads as a distinct floating layer so the inner
                // gray content cards (DashboardScreen's GlassCards) stand out
                // against it; separation from the projects column is the HStack
                // `spacing` gap, not a hairline divider.
                //
                // The 8pt OUTER inset (trailing + bottom) floats the column clear
                // of the window's rounded corners — mirroring the footer block's
                // outer inset in RootView so the two menu blocks are symmetric vs.
                // the window edge. The leading edge takes no inset: the HStack
                // `spacing: 8` already gaps it from the projects column.
                VStack(spacing: 0) {
                    chartsTitle
                    GlassMenuContainer {
                        ChartsSideContent(state: state)
                            // SINGLE ~7pt inner content inset from the clear-block
                            // edge to the graph cards (was a doubled 16pt: 8 here +
                            // 8 in DashboardScreen, now zeroed). Halved so the cards
                            // sit close to the block edge — no giant inner gap.
                            .padding(7)
                            // Pin the cards to the TOP and let the clear glass block
                            // STRETCH to fill the (taller) HStack height, so the
                            // block's bottom rim reaches the footer block's bottom
                            // rim instead of hugging the cards and leaving a
                            // bare-glass band below.
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(maxHeight: 820)
                }
                .padding(.trailing, 8)
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

    /// The charts column's floating H1 ("Usage"), structured IDENTICALLY to
    /// RootShell's "Projects" large title — a 44pt band, `.largeTitle.bold`, a 14pt
    /// top inset, bottom-leading — so the two section titles share one baseline
    /// across the merged window. Indented 7pt to sit over the cards (the glass
    /// block's inner content inset). Unlike "Projects" it never collapses: the
    /// charts column has no ScrollView, so it stays at its at-rest size — which is
    /// exactly the state the "Projects" title is in whenever the list isn't
    /// scrolled (the common case, and the only state snapshots capture).
    private var chartsTitle: some View {
        Text("Usage")
            .font(.largeTitle.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 44, alignment: .bottomLeading)
            .padding(.leading, 7)
            .padding(.top, 14)
            .allowsHitTesting(false)
    }
}
