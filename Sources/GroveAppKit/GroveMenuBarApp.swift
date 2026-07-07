import AppKit
import SwiftUI
import Combine

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

    /// Observes `.groveSubstrateStyleChanged` so the panel live-swaps its substrate
    /// (Liquid Glass ⇄ Visual Effect) without a relaunch when the Settings toggle flips.
    private var substrateObserver: (any NSObjectProtocol)?

    /// Keeps the menu-bar % readout in sync with usage changes + a background refresh
    /// so it stays current while the panel is closed.
    private var usageCancellable: AnyCancellable?
    private var menuReadoutTimer: Timer?

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
            button.action = #selector(togglePanel)
            button.target = self
        }
        item.isVisible = true
        statusItem = item
        updateMenuBarReadout()
        GroveLog.menubar.info("launched; statusItem.isVisible=\(item.isVisible, privacy: .public)")

        // Keep the menu-bar weekly-% readout live: update it whenever usage changes,
        // and refresh usage on a background cadence so it's current with the panel
        // closed (the in-panel 15s loop only runs while the panel is open).
        usageCancellable = state.$usageByAccount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.updateMenuBarReadout() } }
        Task { @MainActor in await state.refreshUsage(now: Date()) }
        menuReadoutTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            // Skip while the panel is open — RootView's 15s loop already refreshes, so
            // the two cadences never overlap (which could land out-of-order and
            // overwrite newer data).
            guard let self, !self.state.isPanelOpen else { return }
            Task { @MainActor in
                await self.state.refreshUsage(now: Date())
                await self.state.reconcileTranscripts()
            }
        }

        // Live-swap the window substrate when the Settings toggle flips the style.
        substrateObserver = NotificationCenter.default.addObserver(
            forName: .groveSubstrateStyleChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reinstallSubstrate() }
        }
        // Warm the heavier screens offscreen shortly after launch so the first
        // navigation is snappy (deferred so the menu-bar icon appears instantly).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { SnapshotMode.prewarm() }

        // Smoke-test seam: GROVE_SMOKE_OPEN_PROJECT=<substr> shows the panel, opens the
        // first matching project (exercising the live glass route change that can't be
        // reproduced in a test process), then self-quits — so a real .app-bundle launch
        // can verify "open a project doesn't crash" headlessly. No-op without the env var.
        if let needle = ProcessInfo.processInfo.environment["GROVE_SMOKE_OPEN_PROJECT"] {
            func smoke(_ s: String) { FileHandle.standardError.write(Data("SMOKE: \(s)\n".utf8)) }
            smoke("hook armed (needle=\(needle))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                self.showPanel()
                smoke("panel shown; isVisible=\(self.panel?.isVisible ?? false)")
                let projects = self.state.config.projects
                if let p = projects.first(where: { $0.name.contains(needle) }) ?? projects.first {
                    smoke("opening project \(p.name)")
                    self.state.open(.project(p.id))
                    smoke("opened project; route=\(self.state.route)")
                } else { smoke("NO matching project") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.state.selectedTab = .stats
                smoke("switched to Stats tab; route=\(self?.state.route as Any)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                smoke("SURVIVED — quitting")
                NSApp.terminate(nil)
            }
        }

        // Recovery seam: if the menu-bar slot is corrupted (icon hidden behind Control
        // Center — clears only on relogin), there's no icon to click. GroveShowOnLaunch
        // (a) shows a DOCK icon so the panel is reachable — clicking it reopens via
        // applicationShouldHandleReopen — and (b) pops the panel on launch. Cleared once
        // the menu-bar icon is restored (relogin).
        if UserDefaults.standard.bool(forKey: "GroveShowOnLaunch") {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.showPanel() }
        }
    }

    /// Re-opening Grove (Finder / Spotlight / Dock, or `open -a Grove`) reopens the
    /// panel instead of being a no-op — a reliable way back in when the menu-bar icon
    /// is hidden by the macOS 26.4 layout-cache bug and there's nothing to click.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if panel?.isVisible != true { showPanel() }
        return true
    }

    /// Renders the menu-bar item as the OVERALL WEEKLY limit: the used % coloured by
    /// severity — adaptive (white on a dark bar) when there's plenty, yellow as it
    /// approaches the cap, red when nearly there. A plain text readout instead of an
    /// icon (the SF-symbol icon failed to render reliably in the menu bar; text is
    /// both robust and more useful at a glance). Shows "–" until the first usage load.
    private func updateMenuBarReadout() {
        guard let button = statusItem?.button else { return }
        button.image = nil
        let font = NSFont.menuBarFont(ofSize: 0)
        if let u = state.menuBarWeeklyUsage() {
            let color: NSColor
            switch u.level {
            case .critical: color = .systemRed
            case .tight:    color = .systemYellow
            case .plenty:   color = .labelColor
            case .noData:   color = .secondaryLabelColor
            }
            button.attributedTitle = NSAttributedString(
                string: "\(u.percent)%", attributes: [.foregroundColor: color, .font: font])
        } else {
            button.attributedTitle = NSAttributedString(
                string: "–", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: font])
        }
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
        // AppKit-level height cap from the start (refined per-screen in applyContentSize)
        // so the panel can never grow off-screen even before the first sizing pass.
        if let vis = NSScreen.main?.visibleFrame {
            p.contentMaxSize = NSSize(width: .greatestFiniteMagnitude, height: max(200, vis.height - 8))
        }
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
        WindowSubstrate.install(h, radius: radius, style: WindowSubstrateStyle.current, in: p)
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

    /// Rebuilds the panel's substrate from the current `WindowSubstrateStyle` (the
    /// Settings toggle), re-parenting the SAME hosting view into the new backing so
    /// the swap is live and lossless — no relaunch, no lost state.
    private func reinstallSubstrate() {
        guard let p = panel, let h = host else { return }
        WindowSubstrate.install(h, radius: DesignRadius.panel, style: WindowSubstrateStyle.current, in: p)
        if h.preferredContentSize.width > 1 { applyContentSize(h.preferredContentSize) }
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
        // on-screen. AppKit-level cap (contentMaxSize): the window can NEVER exceed
        // this regardless of HOW it's resized — setContentSize, a SwiftUI auto-grow
        // from a tall project (many sessions/worktrees), anything. This REPLACES the
        // synchronous cap windowDidResize used to do (removed because re-entrant
        // setContentSize recursed Apple's Liquid Glass to a SIGSEGV): contentMaxSize is
        // a passive constraint, so it needs no setContentSize and can't enter that path.
        let maxH = max(200, visible.height - 8)
        p.contentMaxSize = NSSize(width: .greatestFiniteMagnitude, height: maxH)
        let h = min(size.height, maxH)
        let capped = NSSize(width: size.width, height: h)
        if p.frame.size != capped { p.setContentSize(capped) }
        repinTopRight()
    }

    /// Re-pins the panel's TOP-RIGHT corner to the status icon (grow LEFT + DOWN),
    /// clamped on-screen — WITHOUT resizing. windowDidResize calls THIS, never
    /// applyContentSize: calling setContentSize from inside a resize callback is a
    /// resize-within-a-resize that AppKit runs in an animation group, which recurses
    /// the Liquid-Glass material resolver (DesignLibrary / MaterialProviderBox) to a
    /// stack-overflow SIGSEGV — the "crash when opening a project" (the open resizes
    /// the window). Origin-only repinning can't enter that path.
    private func repinTopRight() {
        guard let p = panel else { return }
        let visible = (anchorScreen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchorRightX - p.frame.width
        x = max(visible.minX + 4, min(x, visible.maxX - p.frame.width - 4))
        var y = anchorTopY - p.frame.height
        y = max(visible.minY + 4, min(y, visible.maxY - p.frame.height - 4))
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
        let screen = buttonWindow.screen ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        anchorScreen = screen
        // A correctly-placed menu-bar icon sits in the menu-bar band at the TOP of its
        // screen. If the slot is corrupted (macOS 26.4 menu-bar-cache bug parks the
        // item at the origin / off-screen), iconRect lands at the BOTTOM-LEFT and the
        // panel would open down there. Detect that and anchor to the screen's TOP-RIGHT
        // instead, so the panel is always reachable in a sane place.
        if iconRect.maxY >= vis.maxY - 6 {
            anchorRightX = iconRect.maxX
            anchorTopY = iconRect.minY - 6            // small gap below the menu bar
        } else {
            anchorRightX = vis.maxX - 8               // fallback: top-right of the screen
            anchorTopY = vis.maxY - 4
        }
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
        // Origin-only re-pin. The height cap is enforced PASSIVELY by the panel's
        // contentMaxSize (set in makePanel + applyContentSize), so we don't resize here
        // — calling setContentSize from inside a resize callback recurses Apple's Liquid
        // Glass to a SIGSEGV (see repinTopRight).
        repinTopRight()
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
