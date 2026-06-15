import AppKit
import SwiftUI

/// A distinct CLEAR Liquid-Glass "menu block" for chrome-level surfaces (the
/// charts panel and the footer) that must read as a floating glass layer ABOVE
/// the window — NOT as another gray content card (GlassCard).
///
/// macOS-26 menus are clear Liquid Glass that refracts what's behind/inside, so
/// the inner gray content cards (GlassCard) stand out crisply against this clear
/// block. We do NOT use SwiftUI's `.glassEffect` / `GlassEffectContainer`: those
/// crash the window-server (EXC_BAD_ACCESS in GlassEffectContextResolvedData)
/// when nested inside the app's AppKit `NSGlassEffectView` window substrate
/// (GlassWindowSubstrate), and they render invisible offscreen.
///
/// Instead this places a NATIVE `NSGlassEffectView` (the SAME class the window
/// substrate uses — proven stable) as a BACKGROUND layer behind the SwiftUI
/// content. The content stays in the normal SwiftUI render tree (so it's visible
/// and SwiftUI drives all sizing), while the glass simply fills behind it: no
/// fragile NSViewRepresentable content-hosting / dynamic-sizing, no SwiftUI glass
/// crash. The clear glass over the window's own glass gives the distinct nested
/// "floating menu" layer.
///
/// Under `\.isSnapshotRender` (ImageRenderer offscreen, which can't draw an
/// AppKit `NSGlassEffectView`) it falls back to a clear fill + a hairline rounded
/// border — same `isSnapshotRender` swap pattern used across the app — so the
/// inner gray cards stay visible in the snapshot PNGs and tests.
struct GlassMenuContainer<Content: View>: View {
    @Environment(\.isSnapshotRender) private var isSnapshotRender
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
            .background {
                if isSnapshotRender {
                    // No AppKit offscreen: a clear block defined only by a faint
                    // hairline so the inner gray cards stand out against it.
                    shape.fill(.white.opacity(0.04))
                } else {
                    GlassMenuBackdrop(cornerRadius: cornerRadius)
                }
            }
            // The hairline that traces the clear block in BOTH modes (the AppKit
            // glass alone reads edgeless against the window glass; this defines
            // the "menu" boundary). Drawn on top so it's never hidden by content.
            .overlay {
                shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            }
    }
}

/// The clear Liquid-Glass backdrop: a native `NSGlassEffectView` in `.clear`
/// style, hosted purely as a background fill (NO SwiftUI content inside, so no
/// representable content-sizing concerns). Composites at the window-server layer,
/// so it never hits the crashing SwiftUI glass path. Clear (not `.regular`)
/// because this floats over the window's OWN `.regular` glass — clear refracts
/// the substrate/content rather than stacking a second frost floor (which would
/// read as muddy glass-on-glass).
private struct GlassMenuBackdrop: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.style = .clear
        glass.cornerRadius = cornerRadius
        glass.tintColor = nil
        return glass
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        nsView.cornerRadius = cornerRadius
    }
}
