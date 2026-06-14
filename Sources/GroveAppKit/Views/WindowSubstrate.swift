import SwiftUI

extension View {
    /// The ONE window chrome shared by both panels (main + Charts): maximally
    /// transparent Liquid Glass + the rounded clip + a hairline border. Defined once
    /// so both windows read identically. No scrim — the gray GlassCards carry the
    /// content contrast, and the window stays as see-through as possible.
    ///
    /// (An NSVisualEffectView substrate was tried to kill the focus-dependent
    /// dimming, but it read noticeably LESS transparent than Liquid Glass, so the
    /// glass is back — same effect on both windows keeps them consistent.)
    func windowChrome(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .glassEffect(.regular, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.10)))
    }
}
