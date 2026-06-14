import AppKit
import SwiftUI

/// The ONE window substrate shared by both panels (main + Charts): macOS 26's
/// native `NSGlassEffectView` in REGULAR style — the same slightly-transparent,
/// small-blur Liquid Glass as SwiftUI's `.glassEffect(.regular)`, but CONSTANT.
///
/// Why `.regular` not `.clear`: clear glass is mostly a lens, so its look is
/// dominated by whatever sits behind the window — over a busy fullscreen surface
/// it suddenly reads as heavy blur, over the desktop as near-transparent, and the
/// two side-by-side panels (over different backdrops) never match. `.regular` has
/// a fixed frost floor, so it reads the SAME regardless of backdrop and on both
/// panels. (The panels also drop `.fullScreenAuxiliary` so they no longer float
/// over fullscreen apps and re-sample that blurry surface — see GroveMenuBarApp.)
///
/// Why AppKit, not SwiftUI `.glassEffect`: SwiftUI's glass reacts to the host
/// window's key/active state — it dims when the window isn't key. With two panels
/// (one key-capable, one canBecomeKey=false) that meant the windows looked
/// different and shifted as focus moved. `NSGlassEffectView` composites at the
/// window-server layer and does NOT consult SwiftUI active state, so identical
/// config on both panels reads identically and never dims. There is exactly one
/// glass layer (the window); the content cards are a plain gray fill (GlassCard),
/// so no glass-on-glass muddiness.
@MainActor
enum GlassWindowSubstrate {
    /// Installs a clear-glass `NSGlassEffectView` as `panel`'s contentView and
    /// embeds `host.view` inside it. The caller keeps `host` for its
    /// preferredContentSize KVO (sizing is driven by setContentSize, not by the
    /// hosting controller). The panel must already be isOpaque=false /
    /// backgroundColor=.clear (Grove's panels are).
    static func install(_ host: NSHostingController<AnyView>, radius: CGFloat, in panel: NSPanel) {
        let glass = NSGlassEffectView()
        glass.style = .regular          // fixed frost floor: constant, identical on both panels
        glass.cornerRadius = radius     // the rounded window shape
        glass.tintColor = nil           // neutral, constant
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear   // let the glass show through the gaps
        host.view.frame = CGRect(origin: .zero, size: panel.frame.size)
        host.view.autoresizingMask = [.width, .height]
        glass.contentView = host.view
        panel.contentView = glass
        // Keep the hosting controller (and its KVO) alive for the panel's lifetime.
        objc_setAssociatedObject(panel, &hostKey, host, .OBJC_ASSOCIATION_RETAIN)
    }

    private static var hostKey: UInt8 = 0
}
