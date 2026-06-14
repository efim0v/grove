import SwiftUI

/// True while SnapshotMode renders offscreen. ImageRenderer draws views
/// modified by .glassEffect as fully INVISIBLE (not merely flat), so glass
/// chrome must swap to a plain translucent card during snapshot rendering.
private struct SnapshotRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSnapshotRender: Bool {
        get { self[SnapshotRenderKey.self] }
        set { self[SnapshotRenderKey.self] = newValue }
    }
}

/// Card chrome used across the app: a GRAY translucent substrate floating on the
/// window's transparent Liquid Glass. The glass is the WINDOW (set on the panel);
/// the content blocks are these neutral gray cards with a pronounced Apple-26
/// continuous radius and a hairline top-edge highlight. A plain fill (not
/// .glassEffect) keeps the card — and everything inside it — visible both live and
/// in the offscreen snapshot renderer. The card declares itself the container
/// shape so nested ConcentricRectangle elements resolve concentric radii against it.
public struct GlassCard: ViewModifier {
    public init() {}

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignRadius.card, style: .continuous)
    }

    public func body(content: Content) -> some View {
        // Darker (white 0.20 → 0.16) and ~10% more transparent (0.78 → 0.70) than
        // before; NO light "glass" border — the substrate reads as a clean dark
        // gray surface floating on the window's Liquid Glass.
        content
            .background(Color(white: 0.16).opacity(0.70), in: shape)
            .containerShape(shape)
    }
}

extension View {
    public func glassCard() -> some View {
        modifier(GlassCard())
    }
}
