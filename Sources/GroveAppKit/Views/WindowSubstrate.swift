import AppKit
import SwiftUI

/// Which substrate backs the merged panel (projects | charts). The two read the
/// SAME across the whole window because there is ONE window over ONE substrate —
/// the transparency fix two side-by-side windows could never give.
///
/// `.liquidGlass` (DEFAULT) is macOS 26's `NSGlassEffectView`; the user validated
/// this look over the alternative. `.visualEffect` is the M1-spec mechanism: a
/// single `NSVisualEffectView` (state = .active ALWAYS, blendingMode = .behindWindow,
/// a very transparent material) + a fixed scrim — offered behind this flag so both
/// substrates are available and switchable at runtime.
enum WindowSubstrateStyle: String, CaseIterable {
    case liquidGlass
    case visualEffect

    var label: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .visualEffect: return "Visual Effect"
        }
    }

    /// Persisted selection (UserDefaults). Defaults to `.liquidGlass`.
    static let defaultsKey = "GroveWindowSubstrateStyle"
    static var current: WindowSubstrateStyle {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(WindowSubstrateStyle.init) ?? .liquidGlass
    }
}

extension Notification.Name {
    /// Posted when the substrate style changes so the panel can live-swap its
    /// contentView without a relaunch.
    static let groveSubstrateStyleChanged = Notification.Name("groveSubstrateStyleChanged")
}

/// Installs the chosen window substrate as `panel.contentView`, embedding
/// `host.view` inside it. ONE entry point ("define it once") for both substrates so
/// the projects and charts sections always share whichever backing is active. The
/// caller keeps `host` for its preferredContentSize KVO. The panel must already be
/// isOpaque=false / backgroundColor=.clear (Grove's panels are). Re-callable: it
/// re-parents `host.view` into a fresh substrate, so the same call live-swaps styles.
@MainActor
enum WindowSubstrate {
    static func install(_ host: NSHostingController<AnyView>, radius: CGFloat,
                        style: WindowSubstrateStyle, in panel: NSPanel) {
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear   // let the substrate show through the gaps
        host.view.autoresizingMask = [.width, .height]
        let substrate: NSView
        switch style {
        case .liquidGlass:  substrate = makeGlass(host: host, radius: radius, size: panel.frame.size)
        case .visualEffect: substrate = makeVisualEffect(host: host, radius: radius, size: panel.frame.size)
        }
        panel.contentView = substrate
        panel.invalidateShadow()
        // Keep the hosting controller (and its KVO) alive for the panel's lifetime.
        objc_setAssociatedObject(panel, &hostKey, host, .OBJC_ASSOCIATION_RETAIN)
    }

    // MARK: - Liquid Glass (NSGlassEffectView) — the default

    /// macOS 26's native Liquid Glass in REGULAR style: a fixed frost floor, so it
    /// reads the SAME regardless of backdrop, and (unlike SwiftUI `.glassEffect`)
    /// composites at the window-server layer so it never dims when the window loses
    /// key state.
    private static func makeGlass(host: NSHostingController<AnyView>, radius: CGFloat,
                                  size: CGSize) -> NSView {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = radius
        glass.tintColor = nil
        host.view.frame = CGRect(origin: .zero, size: size)
        glass.contentView = host.view   // re-parents host.view (removes it from any prior substrate)
        return glass
    }

    // MARK: - Visual Effect (NSVisualEffectView) — the M1-spec substrate

    /// The M1-spec substrate: a single `NSVisualEffectView` configured to be CONSTANT.
    /// `state = .active` ALWAYS so it never dims on focus/hover/click;
    /// `blendingMode = .behindWindow` samples the desktop behind the window; the
    /// `.hudWindow` material is very transparent. A fixed dark scrim sits over the
    /// material (so the content cards still read), and the layer is clipped to the
    /// panel's continuous corner radius. One substrate for the whole merged root, so
    /// the projects and charts sections are identical by construction.
    private static func makeVisualEffect(host: NSHostingController<AnyView>, radius: CGFloat,
                                         size: CGSize) -> NSView {
        let bounds = CGRect(origin: .zero, size: size)
        let effect = NSVisualEffectView(frame: bounds)
        effect.material = .hudWindow            // very transparent
        effect.blendingMode = .behindWindow
        effect.state = .active                  // ALWAYS active — constant regardless of key state
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius     // the rounded window shape…
        effect.layer?.cornerCurve = .continuous // …with Apple's continuous corner, matching the panel
        effect.layer?.masksToBounds = true

        // Fixed scrim: a constant dark wash over the material so the gray content
        // cards stay legible and the substrate reads the same over any backdrop —
        // the "+ identical scrim" half of the M1 recipe.
        let scrim = NSView(frame: bounds)
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
        scrim.autoresizingMask = [.width, .height]
        effect.addSubview(scrim)

        host.view.frame = bounds
        effect.addSubview(host.view)            // re-parents host.view, above the scrim
        return effect
    }

    private static var hostKey: UInt8 = 0
}
