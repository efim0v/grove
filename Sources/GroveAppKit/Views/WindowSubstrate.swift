import SwiftUI
import AppKit

/// The ONE window backdrop, shared by both panels (main + Charts).
///
/// SwiftUI's `.glassEffect(.regular)` changes appearance with the window's KEY
/// state — the main panel can become key and the Charts panel cannot, so the two
/// rendered differently AND the main one visibly dimmed/brightened on every click.
/// An `NSVisualEffectView` pinned to `state = .active` is constant: it never reacts
/// to focus/hover, so both windows read identically and maximally transparently.
struct WindowSubstrateView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground   // one of the most transparent materials
        view.blendingMode = .behindWindow        // sample the desktop behind the panel
        view.state = .active                     // ALWAYS active — never dim on losing key
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        // Re-assert in case AppKit flips state when the window resigns key.
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
    }
}

extension View {
    /// The shared window chrome: the fixed transparent substrate + a faint scrim
    /// (for text legibility over bright desktops) + the rounded clip + hairline
    /// border. Defined ONCE so both windows are byte-identical and never dim.
    func windowChrome(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(Color.black.opacity(0.08))   // shared scrim, over the glass
            .background(WindowSubstrateView())        // fixed transparent glass behind
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.12)))
    }
}
