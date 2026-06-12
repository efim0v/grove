import AppKit
import GroveAppKit
import GroveCore

// main.swift (not @main) so snapshot rendering and the cmux probe can run and
// exit BEFORE any NSApplication/menu-bar machinery starts. main.swift top-level
// code runs on the main thread; assumeIsolated bridges into the @MainActor API.
// CmuxProbe ("--cmux-probe <outFile>", see CmuxProbe.swift and README
// Troubleshooting) parks the main thread in dispatchMain() and never returns
// when the flag is present.
let handledSnapshot = MainActor.assumeIsolated { SnapshotMode.runIfRequested() }
if !handledSnapshot && !CmuxProbe.runIfRequested() {
    MainActor.assumeIsolated { GroveMenuBarApp.run() }
}
