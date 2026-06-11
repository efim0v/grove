# Grove

Menu-bar command center for git-worktree feature workspaces: one umbrella
directory per feature across a multi-repo project, stacked workspaces derived
from git itself, Claude Code sessions/processes per workspace (multi-account),
and one-click jumps into [cmux](https://cmux.dev) terminals. macOS 26+,
SwiftUI + Liquid Glass, zero external dependencies.

## Quickstart

    swift test                          # full suite (core + app), ~1 min
    Scripts/build-app.sh                # builds + ad-hoc signs dist/Grove.app
    cp -R dist/Grove.app /Applications/ # optional install
    open /Applications/Grove.app        # or: open dist/Grove.app

First run: click the tree icon in the menu bar, open Settings (gear), press
"Add project…" and pick the directory that CONTAINS your repos (e.g.
`~/Desktop/acme.shop`). Grove scans it immediately and re-scans every 15 s
while the panel is open. Workspaces live under `~/Workspaces/<project>/<name>`
by default (template configurable in Settings).

Grant nothing: Grove is ad-hoc signed, uses no Apple Events and no
TCC-protected APIs — cmux is driven through its CLI, Claude state is read from
plain files in `~/.claude*`. Rebuilds/reinstalls are therefore prompt-free.

## CLI

    swift build -c release
    .build/release/grove workspaces ~/Desktop/acme.shop
    .build/release/grove scan ~/Desktop/acme.shop
    .build/release/grove --help         # scan/workspaces/sessions/create/graph

## Development

- `swift test` and `swift test -c release` must both stay green (a Swift -O
  miscompile was once caught only in release mode).
- Agent-verifiable UI: `swift run GroveApp --snapshot /tmp/grove-snap` renders
  six fixture PNGs without starting the app — see `docs/snapshot-testing.md`
  for the workflow and the ImageRenderer caveats.
- Config lives at `~/Library/Application Support/Grove/config.json`
  (atomic writes, corrupt files are quarantined with a banner).
