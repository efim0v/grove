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

## Troubleshooting

### "cmux unavailable" although cmux is running

cmux's control socket only accepts clients whose process ancestry traces into
the cmux app (`automation.socketControlMode`, default `"cmuxOnly"`). Commands
work from any cmux-hosted terminal, but Grove launched from Finder/Dock/`open`
descends from launchd, so the server rejects every call ("ERROR: Access denied
— only processes started inside cmux can connect"; the cmux CLI surfaces this
only as "Failed to write to socket (Broken pipe)"). One-time fix in cmux:
Settings > Automation > Socket control mode -> "Automation" (allows external
clients from your user account; equivalently set
`"automation": {"socketControlMode": "automation"}` in `~/.config/cmux/cmux.json`
and `cmux reload-config`). cmux applies the mode when its CLI listener starts,
so afterwards run cmux's "Restart CLI Listener" palette command or restart
cmux once. Alternatively set a socket password in the same settings pane —
Grove reads `automation.socketPassword` from `~/.config/cmux/cmux.json` and
forwards it as `CMUX_SOCKET_PASSWORD` automatically.

### cmux diagnostic probe

`Grove.app` ships a hidden diagnostic flag that runs the exact production cmux
call path (ping, ensure-running, list, create + close a `grove-probe`
workspace) WITHOUT the error-swallowing the UI does, and writes a step-by-step
report (environment, executable resolution, per-step stdout/stderr/error,
raw-socket denial check):

    Scripts/build-app.sh
    open -nW dist/Grove.app --args --cmux-probe /tmp/cmux-probe.txt
    cat /tmp/cmux-probe.txt

Launching through `open` (LaunchServices) is the point: it reproduces the real
GUI context (no TTY, launchd ancestry). `-n` forces a new instance when Grove
is already running. Running the binary directly
(`dist/Grove.app/Contents/MacOS/Grove --cmux-probe /tmp/p.txt`) probes the
terminal context instead — comparing the two reports isolates
context-dependent failures like the socket access mode above.

## Development

- `swift test` and `swift test -c release` must both stay green (a Swift -O
  miscompile was once caught only in release mode).
- Agent-verifiable UI: `swift run GroveApp --snapshot /tmp/grove-snap` renders
  six fixture PNGs without starting the app — see `docs/snapshot-testing.md`
  for the workflow and the ImageRenderer caveats.
- Config lives at `~/Library/Application Support/Grove/config.json`
  (atomic writes, corrupt files are quarantined with a banner).
