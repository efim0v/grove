# Test coverage policy

Run `Scripts/coverage.sh` to measure coverage and enforce the gate.

## The gate: logic layer ≥ 95%

Grove is a SwiftUI menu-bar app. Per standard practice for UI apps, the
unit-coverage **gate** is the **pure / mockable logic layer** — it must stay at
**≥ 95%** line coverage:

- `GroveCore` services (git, claude, usage analytics/reader, workspace, shared
  store, statusline, pricing, rate-limit, config store, process runner, oauth),
- `GroveCore` models (config, errors, paths),
- `GroveAppKit/Presentation/*` (all the pure view-models),
- `GroveAppKit/State/*` (`AppState`, routing).

These are tested directly with fixtures, temp dirs, and injected runners/fetchers
(no real network, git, cmux, or `~/.claude` access).

## Excluded from the gate (validated by other means)

These are **not** unit-testable in isolation; covering them to 95% would require
real external infrastructure or UI automation, which would be brittle and pull in
dependencies the app deliberately avoids (it is zero-dependency):

| Excluded | Why | How it's validated instead |
|----------|-----|----------------------------|
| `GroveAppKit/Views/*`, `DesignSystem`, `GroveLog` | SwiftUI rendering + interactive `@State`/button closures | **Snapshot/render tests** (`SnapshotModeTests`, `DashboardRenderTests`, `ViewStatesRenderTests`) render every scene — both snapshot and live branches — and assert non-empty output, catching layout/render crashes. |
| `GroveMenuBarApp.swift` | `NSApplication`/`NSStatusItem`/`NSPopover` bootstrap | Manual launch (`Scripts/build-app.sh`). |
| `Services/CmuxService`, `Services/CmuxAppleScript` | Drive the real cmux CLI / control socket / `osascript` + a live shell handshake | Their pure/parse logic IS unit-tested with a scripted runner (`CmuxServiceTests`, `CmuxAppleScriptBackendTests`); the real-socket/osascript paths are validated manually and via `Grove --cmux-probe`. |
| `Diagnostics/CmuxProbe.swift` | A manual diagnostic CLI that benchmarks the real cmux socket | Run by hand: `Grove --cmux-probe <out>`. |
| `Snapshot/SnapshotMode.swift` | Is itself the test/render harness | n/a |

The overall (all-files) number is also printed for transparency; it is lower
because it includes the excluded view/integration code above.
