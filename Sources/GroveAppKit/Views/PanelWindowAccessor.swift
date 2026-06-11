import AppKit
import SwiftUI

/// Weak handle to the hosting NSPanel, filled by PanelWindowAccessor once the
/// tracking view lands in a window. RootView keeps it as a @StateObject so it
/// can poke the window again later (invalidateShadow on route/size changes).
@MainActor
final class PanelWindowBridge: ObservableObject {
    weak var window: NSWindow?
}

/// Invisible AppKit hook that makes the MenuBarExtra(.window) panel itself
/// transparent so RootView can draw its OWN large-continuous-corner chrome
/// (macOS 26 look). The system panel keeps pre-26 corner chrome; clearing the
/// window background lets our .glassEffect + clipShape silhouette become the
/// visible window, with the system shadow following the opaque content after
/// invalidateShadow().
struct PanelWindowAccessor: NSViewRepresentable {
    let bridge: PanelWindowBridge

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.bridge = bridge
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.bridge = bridge
    }

    /// viewDidMoveToWindow is the only reliable "I have a window now" signal
    /// for a representable inside MenuBarExtra. Defensive throughout: a nil
    /// window is a no-op, and an already-configured window is never touched
    /// twice (the panel can re-host the same window on every open).
    final class TrackingView: NSView {
        weak var bridge: PanelWindowBridge?
        private weak var configuredWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }   // detached: keep last config
            bridge?.window = window
            guard window !== configuredWindow else { return }
            configuredWindow = window
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.invalidateShadow()
        }
    }
}
