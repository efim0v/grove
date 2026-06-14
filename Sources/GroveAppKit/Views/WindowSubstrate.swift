import AppKit
import SwiftUI

/// The ONE window substrate shared by both panels (main + Charts): macOS 26's
/// native `NSGlassEffectView` in CLEAR style — maximally transparent, minimally
/// blurred ("чистое" Liquid Glass, not frosted soap), and CONSTANT.
///
/// Why AppKit, not SwiftUI `.glassEffect`: SwiftUI's glass reacts to the host
/// window's key/active state — it drops to a plain blur when the window isn't key
/// (and `.regular` is the frosted, blurry variant). With two side-by-side panels
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
        glass.style = .clear            // maximally transparent, minimal blur — NOT frosted
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
