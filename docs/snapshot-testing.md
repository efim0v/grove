# Snapshot testing (agent-verifiable UI)

## How to render

    swift run GroveApp --snapshot /tmp/grove-snap     # prints "snapshot: 6 files", exits

Six scenes, each 760x520 @2x (1520x1040 px), defined in
`Sources/GroveAppKit/Snapshot/SnapshotMode.swift` (`SnapshotScene`):
root-workspaces, workspaces-expanded, create-sheet, graph, accounts, settings.
The state comes from `SnapshotMode.fixtureState()` — fully synthetic
(no git, no disk scanning, no real config); see the coverage matrix in that file.
Ages are relative to render-time `Date()`, so badge buckets stay truthful.

## Regression workflow (Tasks 19-23 and any later UI change)

1. Change view code.
2. `swift test` (fixture invariants live in SnapshotModeTests).
3. Re-render: `rm -rf /tmp/grove-snap && swift run GroveApp --snapshot /tmp/grove-snap`.
4. READ the affected PNG(s) and check the task's visual assertions
   (structure + text content, never glass/blur).
5. Commit code only — PNGs are throwaway artifacts, never committed.

## ImageRenderer caveats (empirically verified on macOS 26.4)

- `.glassEffect`-modified views render INVISIBLE offscreen (not merely flat).
  GlassCard swaps to fill+border when `\.isSnapshotRender` is true. Any new glass
  chrome must respect the same flag.
- AppKit-backed controls (e.g. `Picker(.segmented)`) render as a yellow error
  placeholder. Use pure-SwiftUI equivalents in snapshot-visible chrome.
- `ScrollView`/`List` content is NOT rendered offscreen. Screens that must be
  snapshot-verifiable should render their content unscrolled (plain stacks) or
  swap the container when `\.isSnapshotRender` is true.
- The PNG background is a stand-in gradient: there is no desktop/panel material
  offscreen. Real glass is verified by the Task 23 manual launch smoke, not here.
