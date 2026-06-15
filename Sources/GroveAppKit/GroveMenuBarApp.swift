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
/// This single panel hosts BOTH sections (projects + charts) via MergedRootView.
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
    /// (a tab/route switch, or collapsing/showing the charts section) — an NSWindow
    /// does not do this on its own reliably.
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
        // Initial rect sized for the default (showCharts == true) combined layout —
        // projects 460 + 8px gap + charts BLOCK (290 + 8px padding ×2 = 306) = 774 —
        // so the first frame doesn't flash at the projects-only width before KVO
        // corrects it. Height is the charts-driven 600; the first
        // preferredContentSize callback corrects both.
        let p = GrovePanel(contentRect: NSRect(x: 0, y: 0, width: 774, height: 600),
                           styleMask: [.borderless],
                           backing: .buffered, defer: false)
        p.level = .floating                  // above normal windows, but NOT forced over fullscreen apps
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        // Show on the current Space when summoned, but do NOT float over fullscreen
        // apps or ride along during a Space swipe — that re-samples a dense/blurry
        // backdrop and makes the constant glass suddenly intensify (the user's #1
        // complaint). `.moveToActiveSpace` brings the panel to the active Space on
        // demand without persisting across Spaces.
        p.collectionBehavior = [.moveToActiveSpace]
        p.delegate = self

        // The panel supplies the chrome the popover used to: a glass material under
        // RootView's dark scrim, clipped to the Apple-26 panel radius, hairline edge.
        // isOpaque=false + clear bg makes the window-server shadow follow the rounded
        // shape; invalidateShadow() on resize keeps it in sync.
        // Clear, constant Liquid Glass via AppKit NSGlassEffectView — never frosted,
        // never dims on focus (see GlassWindowSubstrate). ONE substrate now wraps the
        // WHOLE merged root (projects | divider | charts), so both sections read
        // identically — the transparency fix that two separate windows could never
        // give. The hairline border is drawn on MergedRootView; the gray GlassCards
        // provide content surfaces.
        let radius = DesignRadius.panel
        let chrome = AnyView(MergedRootView(state: state))
        let h = NSHostingController(rootView: chrome)
        h.sizingOptions = [.preferredContentSize]
        GlassWindowSubstrate.install(h, radius: radius, in: p)
        host = h
        // Resize the panel to the SwiftUI content on every tab/route change (or a
        // charts collapse/show), then re-pin the top-right corner so it grows inward
        // instead of jumping.
        sizeObservation = h.observe(\.preferredContentSize) { [weak self] controller, _ in
            let size = controller.preferredContentSize
            DispatchQueue.main.async { self?.applyContentSize(size) }
        }
        panel = p
        return p
    }

    /// Resizes the single merged panel to its SwiftUI content and re-pins its
    /// TOP-RIGHT corner to the status-item icon, so the window grows LEFTWARD and
    /// DOWNWARD as the route changes (or the charts section collapses/expands) —
    /// the right edge stays glued under the icon instead of the window jumping.
    /// This is the old anchorChartsToIcon math (top-right pinned, on-screen clamp)
    /// applied to the one window that now holds both sections.
    private func applyContentSize(_ size: NSSize) {
        guard let p = panel, size.width > 1, size.height > 1 else { return }
        let visible = (anchorScreen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Cap the height to the visible screen so the window can always be fully
        // on-screen (the dashboard has no scroll view; a too-tall charts column
        // would otherwise push the top above the menu bar on short displays).
        let h = min(size.height, visible.height - 8)
        let capped = NSSize(width: size.width, height: h)
        if p.frame.size != capped { p.setContentSize(capped) }
        // Top-RIGHT corner pinned to the icon; grow LEFT + DOWN, then clamp on-screen.
        var x = anchorRightX - capped.width
        x = max(visible.minX + 4, min(x, visible.maxX - capped.width - 4))
        var y = anchorTopY - capped.height
        y = max(visible.minY + 4, min(y, visible.maxY - capped.height - 4))
        p.setFrameOrigin(NSPoint(x: x, y: y))
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
        state.isPanelOpen = true                  // starts RootView's refresh loop
        // Size + place the merged panel BEFORE ordering in so it doesn't flash.
        // NSHostingController can still report 0x0 before its first layout pass, so
        // when no preferred size is known yet, anchor using the panel's CURRENT
        // frame (the initial 774x600, or the last shown size) — the top-right corner
        // must be pinned to the icon BEFORE makeKeyAndOrderFront, or the very first
        // open flashes at the window's default origin until the KVO repositions it.
        if let h = host, h.preferredContentSize.width > 1 {
            applyContentSize(h.preferredContentSize)
        } else {
            applyContentSize(p.frame.size)
        }
        NSApp.activate(ignoringOtherApps: true)   // key window + keyboard for an .accessory app
        p.makeKeyAndOrderFront(nil)               // key-capable: the search field gets focus
        installOutsideClickMonitor()
    }

    private func hidePanel() {
        state.isPanelOpen = false                 // stops RootView's refresh loop
        panel?.orderOut(nil)
        removeOutsideClickMonitor()
    }

    /// A resize of the merged panel (a route change or a charts collapse/show)
    /// re-pins its top-right corner to the icon and refreshes the shadow.
    func windowDidResize(_ notification: Notification) {
        let resized = notification.object as? NSWindow
        // A resize delivered while the window is hidden (a SwiftUI layout pass during
        // orderOut) must not reposition with stale anchors — showPanel re-anchors.
        guard resized === panel, resized?.isVisible == true else { return }
        applyContentSize(panel?.frame.size ?? .zero)
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
