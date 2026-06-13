import AppKit
import SwiftUI

/// Menu-bar entry point. Uses a plain AppKit `NSStatusItem` + `NSPopover`
/// hosting the SwiftUI `RootView`, NOT SwiftUI's `MenuBarExtra`.
///
/// Why not `MenuBarExtra`: on macOS 26.4 its scene machinery sends `terminate:`
/// to the app moments after the status item appears, so the process quits at
/// launch. A manual `NSStatusItem` has no such scene lifecycle. (Its repeated
/// visibility toggling also corrupted the WindowServer menu-bar layout cache for
/// the old `dev.artem.grove` identity, pinning the icon off-screen behind
/// Control Center — hence the fresh `dev.artemefimov.grove` bundle id.)
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

/// Owns the status item and the popover that hosts the SwiftUI panel.
@MainActor
private final class StatusBarController: NSObject, NSApplicationDelegate {
    /// Single shared state for the lifetime of the process.
    private let state = AppState()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    /// Global mouse monitor installed while the panel is open so a click
    /// anywhere OUTSIDE it (desktop, another app) dismisses it (item 1).
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Icon only — no text label beside the tree (item 3).
            let image = NSImage(systemSymbolName: "tree", accessibilityDescription: "Grove")
            image?.isTemplate = true
            button.image = image
            button.action = #selector(togglePopover)
            button.target = self
        }
        item.isVisible = true
        statusItem = item

        popover.behavior = .transient
        popover.animates = true
        // The popover tracks RootView's per-route .frame(...) so it resizes the
        // same way the old MenuBarExtra(.window) panel did.
        let hosting = NSHostingController(rootView: RootView(state: state))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        GroveLog.menubar.info("launched; statusItem.isVisible=\(item.isVisible, privacy: .public)")
    }

    @objc private func togglePopover() {
        if popover.isShown { closePopover() } else { showPopover() }
    }

    /// Shows the panel anchored to the status button. Because the button now sits
    /// at a correct, settled position (the bundle-id fix), `relativeTo:of:` lands
    /// the panel under the icon with its trailing edge by the icon — never
    /// elsewhere on screen (item 6). The min-Y edge puts it just below the menu bar.
    private func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installOutsideClickMonitor()
    }

    private func closePopover() {
        popover.performClose(nil)
        removeOutsideClickMonitor()
    }

    /// A `.transient` popover is supposed to auto-dismiss on an outside click, but
    /// for an `.accessory` app that we force-activate it does so unreliably. A
    /// global monitor (fires only for events in OTHER apps, never inside our own
    /// panel) guarantees the click-away dismissal the user expects (item 1).
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}
