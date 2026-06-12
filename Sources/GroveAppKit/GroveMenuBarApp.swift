import AppKit
import SwiftUI

/// Menu-bar entry point. Uses a plain AppKit `NSStatusItem` + `NSPopover`
/// hosting the SwiftUI `RootView`, NOT SwiftUI's `MenuBarExtra`.
///
/// Why not `MenuBarExtra`: on macOS 26.4 its scene machinery sends `terminate:`
/// to the app moments after the status item appears (a status-item visibility
/// action immediately followed by a graceful app termination), so the process
/// quits at launch — the icon only flashes. Verified by reproducing the same
/// `terminate:` on the pre-change build. A manual `NSStatusItem` has no such
/// scene lifecycle, so the process stays resident.
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
    /// Single shared state for the lifetime of the process (was a static on the
    /// old SwiftUI App; now owned by the controller).
    private let state = AppState()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "tree", accessibilityDescription: "Grove")
            image?.isTemplate = true
            button.image = image
            button.action = #selector(togglePopover)
            button.target = self
        }
        statusItem = item

        popover.behavior = .transient
        popover.animates = true
        // The popover tracks RootView's per-route .frame(...) so it resizes the
        // same way the old MenuBarExtra(.window) panel did.
        let hosting = NSHostingController(rootView: RootView(state: state))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
