import AppKit
import GroveAppKit

// main.swift (not @main) so snapshot rendering can run and exit BEFORE any
// NSApplication/menu-bar machinery starts. main.swift top-level code runs on
// the main thread; assumeIsolated bridges into the @MainActor API.
let handledSnapshot = MainActor.assumeIsolated { SnapshotMode.runIfRequested() }
if !handledSnapshot {
    GroveMenuBarApp.main()
}
