import AppKit
import SwiftUI

/// The ONE window substrate spanning the whole merged panel (projects | divider |
/// charts): macOS 26's native `NSGlassEffectView` in REGULAR style — the same
/// slightly-transparent, small-blur Liquid Glass as SwiftUI's
/// `.glassEffect(.regular)`, but CONSTANT.
///
/// Why `.regular` not `.clear`: clear glass is mostly a lens, so its look is
/// dominated by whatever sits behind the window — over a busy fullscreen surface
/// it suddenly reads as heavy blur, over the desktop as near-transparent. `.regular`
/// has a fixed frost floor, so it reads the SAME regardless of backdrop. (Merging
/// the old two side-by-side panels into ONE window over ONE substrate is what makes
/// the projects and charts sections read identically — two windows over different
/// backdrops never could. The panel also drops `.fullScreenAuxiliary` so it no
/// longer floats over fullscreen apps and re-samples that blurry surface — see
/// GroveMenuBarApp.)
///
/// Why AppKit, not SwiftUI `.glassEffect`: SwiftUI's glass reacts to the host
/// window's key/active state — it dims when the window isn't key. `NSGlassEffectView`
/// composites at the window-server layer and does NOT consult SwiftUI active state,
/// so it reads identically and never dims. There is exactly one glass layer (the
/// one window); the content cards are a plain gray fill (GlassCard), so no
/// glass-on-glass muddiness.
@MainActor
enum GlassWindowSubstrate {
    /// Installs a clear-glass `NSGlassEffectView` as `panel`'s contentView and
    /// embeds `host.view` inside it. The caller keeps `host` for its
    /// preferredContentSize KVO (sizing is driven by setContentSize, not by the
    /// hosting controller). The panel must already be isOpaque=false /
    /// backgroundColor=.clear (Grove's panels are).
    static func install(_ host: NSHostingController<AnyView>, radius: CGFloat, in panel: NSPanel) {
        let glass = NSGlassEffectView()
        glass.style = .regular          // fixed frost floor: constant across the whole window
        glass.cornerRadius = radius     // the rounded window shape
        glass.tintColor = nil           // neutral, constant
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear   // let the glass show through the gaps
        host.view.frame = CGRect(origin: .zero, size: panel.frame.size)
        host.view.autoresizingMask = [.width, .height]
        glass.contentView = host.view   // the whole MergedRootView (projects|divider|charts)
        panel.contentView = glass
        // Keep the hosting controller (and its KVO) alive for the panel's lifetime.
        objc_setAssociatedObject(panel, &hostKey, host, .OBJC_ASSOCIATION_RETAIN)
    }

    private static var hostKey: UInt8 = 0
}
