import AppKit
import SwiftUI

/// Menu-bar entry point. A plain AppKit `NSStatusItem` + a borderless `NSPanel`
/// hosting the SwiftUI `RootView` — NOT SwiftUI's `MenuBarExtra` and NOT an
/// `NSPopover`.
///
/// Why not `MenuBarExtra`: on macOS 26.4 its scene machinery sends `terminate:`
/// to the app moments after the status item appears, so the process quits at
/// launch. (Its repeated visibility toggling also corrupted the WindowServer
/// menu-bar layout cache for the old `dev.artem.grove` identity — hence the
/// fresh `dev.artemefimov.grove` bundle id.)
///
/// Why not `NSPopover`: a popover re-positions itself relative to the status
/// button on EVERY content-size change, re-centering under the icon. Grove's
/// panel changes size when the tab/route changes (Projects ↔ Charts ↔ a project
/// scope), so the popover visibly jumped on each switch. A panel we position
/// ourselves can keep its TOP-RIGHT corner pinned to the icon and grow inward,
/// which also gives the exact right-edge alignment the design calls for.
///
/// `run()` is called from main.swift AFTER SnapshotMode/CmuxProbe (which must
/// run and exit BEFORE any NSApplication machinery starts).
public enum GroveMenuBarApp {
    /// Strong reference to the delegate (NSApplication only holds it weakly).
    @MainActor private static var controller: StatusBarController?

    @MainActor
    public static func run() {
        let app = NSApplication.shared
        let controller = StatusBarController()
        Self.controller = controller
        app.delegate = controller
        app.setActivationPolicy(.accessory)   // menu-bar resident, no Dock tile
        app.run()
    }
}

/// Borderless panel that can still become key, so the panel's search field and
/// other controls receive keyboard input (a plain borderless window cannot).
final class GrovePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the status item and the panel that hosts the SwiftUI `RootView`.
@MainActor
private final class StatusBarController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Single shared state for the lifetime of the process.
    private let state = AppState()
    private var statusItem: NSStatusItem?
    private var panel: GrovePanel?
    private var host: NSHostingController<AnyView>?
    /// KVO token: the panel must resize when SwiftUI's preferredContentSize changes
    /// (a tab/route switch) — an NSWindow does not do this on its own reliably.
    private var sizeObservation: NSKeyValueObservation?
    /// Global mouse monitor installed while the panel is open so a click anywhere
    /// OUTSIDE our app (desktop, another app, the menu bar) dismisses it. A global
    /// monitor never fires for clicks inside our own windows — including a child
    /// NSOpenPanel — so the "+ Add project" flow is not torn down.
    private var outsideClickMonitor: Any?

    /// Anchor captured when the panel opens: the icon's right-edge X and the Y just
    /// below the menu bar, in screen coordinates, plus the screen it lives on. The
    /// panel's top-right corner is pinned here through every resize.
    private var anchorRightX: CGFloat = 0
    private var anchorTopY: CGFloat = 0
    private var anchorScreen: NSScreen?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Icon only — no text label beside the tree.
            let image = NSImage(systemSymbolName: "tree", accessibilityDescription: "Grove")
            image?.isTemplate = true
            button.image = image
            button.action = #selector(togglePanel)
            button.target = self
        }
        item.isVisible = true
        statusItem = item
        GroveLog.menubar.info("launched; statusItem.isVisible=\(item.isVisible, privacy: .public)")
    }

    // MARK: - Panel lifecycle

    private func makePanel() -> GrovePanel {
        if let panel { return panel }
        // NOT .nonactivatingPanel: that flag blocks the panel from becoming key, so
        // the search field would never get the keyboard. Plain .borderless +
        // GrovePanel.canBecomeKey + NSApp.activate gives it focus.
        let p = GrovePanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                           styleMask: [.borderless],
                           backing: .buffered, defer: false)
        p.level = .popUpMenu                 // above normal windows, like a menu
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self

        // The panel supplies the chrome the popover used to: a glass material under
        // RootView's dark scrim, clipped to the Apple-26 panel radius, hairline edge.
        // isOpaque=false + clear bg makes the window-server shadow follow the rounded
        // shape; invalidateShadow() on resize keeps it in sync.
        let radius = DesignRadius.panel
        let chrome = AnyView(RootView(state: state)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.08))))
        let h = NSHostingController(rootView: chrome)
        h.sizingOptions = [.preferredContentSize]
        p.contentViewController = h
        host = h
        // Resize the panel to the SwiftUI content on every tab/route change, then
        // re-pin the top-right corner so it grows inward instead of jumping.
        sizeObservation = h.observe(\.preferredContentSize) { [weak self] controller, _ in
            let size = controller.preferredContentSize
            DispatchQueue.main.async { self?.applyContentSize(size) }
        }
        panel = p
        return p
    }

    /// Resizes the panel to `size` (the SwiftUI content) and re-pins the top-right
    /// corner to the icon — so a content-size change never re-centers/jumps it.
    private func applyContentSize(_ size: NSSize) {
        guard let p = panel, size.width > 1, size.height > 1 else { return }
        if p.frame.size != size { p.setContentSize(size) }
        repositionToAnchor()
        p.invalidateShadow()
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let p = makePanel()
        let iconRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        anchorRightX = iconRect.maxX
        anchorTopY = iconRect.minY - 6            // small gap below the menu bar
        anchorScreen = buttonWindow.screen
        if let h = host, h.preferredContentSize.width > 1 {
            applyContentSize(h.preferredContentSize)
        } else {
            repositionToAnchor()
        }
        state.isPanelOpen = true                  // starts RootView's refresh loop
        NSApp.activate(ignoringOtherApps: true)   // key window + keyboard for an .accessory app
        p.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
    }

    private func hidePanel() {
        state.isPanelOpen = false                 // stops RootView's refresh loop
        panel?.orderOut(nil)
        removeOutsideClickMonitor()
    }

    /// Any resize re-pins the TOP-RIGHT corner to the icon so the panel grows
    /// left/down instead of jumping, and refreshes the rounded window shadow.
    func windowDidResize(_ notification: Notification) {
        repositionToAnchor()
        panel?.invalidateShadow()
    }

    private func repositionToAnchor() {
        guard let p = panel else { return }
        let size = p.frame.size
        var x = anchorRightX - size.width             // right edge aligned to the icon
        var y = anchorTopY - size.height              // top just below the menu bar
        let visible = (anchorScreen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        x = max(visible.minX + 4, min(x, visible.maxX - size.width - 4))
        y = max(visible.minY + 4, y)
        let origin = NSPoint(x: x, y: y)
        if p.frame.origin != origin { p.setFrameOrigin(origin) }
    }

    // MARK: - Outside-click dismissal

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hidePanel()
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}
