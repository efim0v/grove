import SwiftUI

/// A distinct CLEAR "menu block" for chrome-level surfaces (the charts panel and
/// the footer) that must read as a floating layer ABOVE the window — NOT as another
/// gray content card (GlassCard).
///
/// The window itself is Liquid Glass (the AppKit NSGlassEffectView substrate). This
/// block is a near-transparent fill that lets that window glass show THROUGH (so it
/// reads as clear glass, not a gray card), with a hairline rim to define the
/// floating block so the inner gray content cards (GlassCard) stand out crisply.
///
/// Deliberately PURE SwiftUI — no `.glassEffect`/`GlassEffectContainer` (crashed the
/// window-server in GlassEffectContextResolvedData) and no SwiftUI `Material` or
/// nested `NSGlassEffectView` background (those recursed in MaterialProviderBox /
/// resolveLayers → stack overflow when a Material resolved its backdrop through the
/// nested AppKit glass during a route animation). A flat translucent fill + border
/// can't reach either crashing path and renders identically live and offscreen.
struct GlassMenuContainer<Content: View>: View {
    private let cornerRadius: CGFloat
    private let content: Content

    init(cornerRadius: CGFloat = DesignRadius.card, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            // Concentric nesting: inner GlassCard elements resolve their radii
            // against this clear block's shape.
            .containerShape(shape)
            .background(shape.fill(.white.opacity(0.04)))
            .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
    }
}
