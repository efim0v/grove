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

/// The Charts side window. It must NEVER become key: it holds only display +
/// click controls (the ‹ › scope arrows, which respond to mouse clicks without
/// key status), so keeping it non-key leaves the MAIN panel key — its search
/// field stays focused and ⌘R/⌘Q keep working even while the user clicks around
/// the charts. (A borderless NSPanel is non-key by default; this is explicit.)
final class ChartsDisplayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
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

    /// The always-on Charts side window, docked to the LEFT of the main panel.
    /// Opens/closes with the main panel and re-glues to its left edge on every
    /// resize/move, so the two windows stand side by side regardless of which
    /// section the main panel is showing.
    private var chartsPanel: ChartsDisplayPanel?
    private var chartsHost: NSHostingController<AnyView>?
    private var chartsSizeObservation: NSKeyValueObservation?
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
        // Warm the heavier screens offscreen shortly after launch so the first
        // navigation is snappy (deferred so the menu-bar icon appears instantly).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { SnapshotMode.prewarm() }
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
        // Real Liquid Glass for the window itself — transparent, refractive (not a
        // flat blur). The content sits on this glass; gray cards (GlassCard) provide
        // the content surfaces. Live-only path (snapshots render RootView directly).
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let chrome = AnyView(RootView(state: state)
            .glassEffect(.regular, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.12))))
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

    /// Resizes the MAIN (projects) panel to its SwiftUI content. The main panel is
    /// the one that changes size often, so it sits on the LEFT and grows leftward —
    /// its right edge stays glued just left of the fixed, icon-anchored Charts
    /// window, which never moves on a route change.
    private func applyContentSize(_ size: NSSize) {
        guard let p = panel, size.width > 1, size.height > 1 else { return }
        if p.frame.size != size { p.setContentSize(size) }
        dockMainLeftOfCharts()
        p.invalidateShadow()
    }

    /// Builds (once) the borderless Charts side window — same chrome as the main
    /// panel, hosting the standalone dashboard.
    private func makeChartsPanel() -> ChartsDisplayPanel {
        if let chartsPanel { return chartsPanel }
        let p = ChartsDisplayPanel(contentRect: NSRect(x: 0, y: 0, width: ChartsSideContent.width, height: 600),
                                   styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        let radius = DesignRadius.panel
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let chrome = AnyView(ChartsSideContent(state: state)
            .frame(maxHeight: 820)
            .glassEffect(.regular, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.12))))
        let h = NSHostingController(rootView: chrome)
        h.sizingOptions = [.preferredContentSize]
        p.contentViewController = h
        chartsHost = h
        chartsSizeObservation = h.observe(\.preferredContentSize) { [weak self] controller, _ in
            let size = controller.preferredContentSize
            DispatchQueue.main.async { self?.applyChartsContentSize(size) }
        }
        chartsPanel = p
        return p
    }

    private func applyChartsContentSize(_ size: NSSize) {
        guard let p = chartsPanel, size.width > 1, size.height > 1 else { return }
        // Cap the height to the visible screen so the window can always be fully
        // on-screen (the dashboard has no scroll view; a too-tall window would
        // otherwise push its top above the menu bar on short displays).
        let visible = (anchorScreen ?? NSScreen.main)?.visibleFrame
        let capped = NSSize(width: size.width,
                            height: min(size.height, (visible?.height ?? size.height) - 8))
        if p.frame.size != capped { p.setContentSize(capped) }
        anchorChartsToIcon()
        dockMainLeftOfCharts()   // the Charts window moved → re-glue the main panel
        p.invalidateShadow()
    }

    /// Anchors the CHARTS window's top-RIGHT corner to the status-item icon. Charts
    /// is the FIXED reference (it rarely changes size), so it owns the icon anchor.
    /// Clamped fully on-screen.
    private func anchorChartsToIcon() {
        guard let charts = chartsPanel else { return }
        let size = charts.frame.size
        let visible = (anchorScreen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchorRightX - size.width
        x = max(visible.minX + 4, min(x, visible.maxX - size.width - 4))
        var y = anchorTopY - size.height
        y = max(visible.minY + 4, min(y, visible.maxY - size.height - 4))
        let origin = NSPoint(x: x, y: y)
        if charts.frame.origin != origin { charts.setFrameOrigin(origin) }
    }

    /// Docks the MAIN (projects) window to the LEFT of the anchored Charts window —
    /// right edge a gap left of Charts' left edge, tops aligned — so it grows
    /// leftward as routes change. Falls back to the right of Charts if there's no
    /// room on the left; both axes clamped on-screen.
    private func dockMainLeftOfCharts() {
        guard let main = panel, let charts = chartsPanel else { return }
        let gap: CGFloat = 8
        let size = main.frame.size
        let chartsFrame = charts.frame
        let visible = (anchorScreen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = chartsFrame.minX - gap - size.width
        if x < visible.minX + 4 { x = chartsFrame.maxX + gap }
        x = max(visible.minX + 4, min(x, visible.maxX - size.width - 4))
        var y = chartsFrame.maxY - size.height
        y = max(visible.minY + 4, min(y, visible.maxY - size.height - 4))
        let origin = NSPoint(x: x, y: y)
        if main.frame.origin != origin { main.setFrameOrigin(origin) }
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let p = makePanel()
        let cp = makeChartsPanel()
        let iconRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        anchorRightX = iconRect.maxX
        anchorTopY = iconRect.minY - 6            // small gap below the menu bar
        anchorScreen = buttonWindow.screen
        state.isPanelOpen = true                  // starts RootView's refresh loop
        // Charts is the icon-anchored fixed window (RIGHT); the projects panel docks
        // to its LEFT. Size + place both BEFORE ordering in so neither flashes.
        if let ch = chartsHost, ch.preferredContentSize.height > 1 {
            applyChartsContentSize(ch.preferredContentSize)
        } else {
            anchorChartsToIcon()
        }
        if let h = host, h.preferredContentSize.width > 1 {
            applyContentSize(h.preferredContentSize)
        } else {
            dockMainLeftOfCharts()
        }
        NSApp.activate(ignoringOtherApps: true)   // key window + keyboard for an .accessory app
        cp.orderFront(nil)                         // display-only; main keeps key
        p.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
    }

    private func hidePanel() {
        state.isPanelOpen = false                 // stops RootView's refresh loop
        chartsPanel?.orderOut(nil)
        panel?.orderOut(nil)
        removeOutsideClickMonitor()
    }

    /// A main-panel resize re-docks it to the left of the fixed Charts window; a
    /// Charts resize re-anchors Charts to the icon, then re-docks the main panel.
    func windowDidResize(_ notification: Notification) {
        let resized = notification.object as? NSWindow
        // A resize delivered while the window is hidden (a SwiftUI layout pass during
        // orderOut) must not reposition with stale anchors — showPanel re-anchors.
        guard resized?.isVisible == true else { return }
        if resized === chartsPanel {
            anchorChartsToIcon()
            chartsPanel?.invalidateShadow()
            dockMainLeftOfCharts()
        } else if resized === panel {
            dockMainLeftOfCharts()
            panel?.invalidateShadow()
        }
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
