import SwiftUI

/// Menu-bar app scene. Lives in GroveAppKit so the executable target stays a
/// thin main.swift (which must run SnapshotMode BEFORE NSApplication starts).
public struct GroveMenuBarApp: App {
    /// Single shared state for the lifetime of the process.
    @MainActor private static let sharedState = AppState()

    public init() {}

    public var body: some Scene {
        MenuBarExtra("Grove", systemImage: "tree") {
            RootView(state: Self.sharedState)
        }
        .menuBarExtraStyle(.window)
    }
}
