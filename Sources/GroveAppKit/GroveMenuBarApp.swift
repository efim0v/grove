import SwiftUI

/// Menu-bar app scene. Lives in GroveAppKit so the executable target stays a
/// thin main.swift (which must run SnapshotMode BEFORE NSApplication starts).
public struct GroveMenuBarApp: App {
    /// Single shared state for the lifetime of the process.
    @MainActor private static let sharedState = AppState()

    public init() {}

    /// Remaining 5h capacity across accounts, surfaced in the menu-bar title so the
    /// burn-down goal is visible without opening the panel. FIX I4: before any
    /// capture exists the aggregate has total == 0 — show "—", NOT "0%".
    @MainActor private static var menuBarTitle: String {
        let agg = sharedState.aggregateRemaining(window: .fiveHour, now: Date())
        let badge = AggregateBadge(agg)
        return badge.hasData ? "\(Int((agg.fraction * 100).rounded()))%" : "—"
    }

    public var body: some Scene {
        MenuBarExtra(Self.menuBarTitle, systemImage: "tree") {
            RootView(state: Self.sharedState)
        }
        .menuBarExtraStyle(.window)
    }
}
