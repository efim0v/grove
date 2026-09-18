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

Grant nothing: Grove uses no Apple Events and no TCC-protected APIs — cmux is
driven through its CLI, Claude state is read from plain files in `~/.claude*`.
Rebuilds/reinstalls are therefore prompt-free. Per-account rate limits and
subscriptions are Brow's (below): it is the only one of the two apps that reads
Claude Code's credentials.

## CLI

    swift build -c release
    .build/release/grove workspaces ~/Desktop/acme.shop
    .build/release/grove scan ~/Desktop/acme.shop
    .build/release/grove --help         # scan/workspaces/sessions/create/graph

## Brow

A second, minimal app in this package: it shows every Claude account's rate
limits from the notch (readouts beside the notch, hover for a per-account
panel). Build with `Scripts/build-brow.sh` → `dist/Brow.app`.

Grove and Brow are two related utilities that share one module and a handful of
on-disk contracts (account folders, the per-account browser router, statusline
captures). How they fit together, and what must change in lockstep:
[`docs/grove-and-brow.md`](docs/grove-and-brow.md).

- Accounts are discovered from `~/.claude` and `~/.claude-accounts/*`; dirs that
  belong to the same organisation are shown once.
- On first launch macOS asks once per account for access to Claude Code's
  Keychain item — choose "Always Allow".
- Idle accounts' tokens are kept fresh by running `claude doctor` in that
  account (no model call). If that ever stops working, the `claude -p` fallback
  (Settings → Accounts, **on by default**) spends a little limit and starts the
  account's 5-hour window. It is never used after a 401/403 or a `doctor` that
  timed out — neither is evidence the token itself can be fixed — and it is
  dropped for good after three ineffective rounds.
- The usage endpoint is rate-limited server-side (measured: a small token bucket
  refilled at roughly one request per 100 s, `retry-after: 0`, and 429s that do
  not extend the window). Brow paces itself to it: background polls that arrive
  before the window re-opens are served from the last reading, the ⟳ button
  spends a small burst budget and otherwise queues itself for the moment a
  request will go through (`Updated 2 min ago · retrying in 47 s`). Claude Code's
  own usage numbers come from response headers, which is why it never "hits" this.
- In the panel, every account carries two buttons: copy the command that runs
  Claude Code as that account (`CLAUDE_CONFIG_DIR='…' claude`) and open it in
  Terminal. The same command sits in each account's Settings card.
- Add an account from Settings with one click (**Sign in…**): Brow creates
  `~/.claude-accounts/account-N` itself and opens Terminal with `claude auth login`;
  sign-in happens in Anthropic's own flow.
- Limits are re-fetched every **60 s** by one timer that keeps running whether the
  panel is open or shut, plus on wake, on the network returning, and on hover when
  the data on screen is more than 60 s old. The footer always leads with the age
  (`Updated 3 h ago`), so a number you can see is a number you can date.
- **Settings → General → Ears** chooses where the two readouts sit on a built-in
  display: `Beside the notch` (default — one wing each side, the notch itself left
  clear) or `Below the notch` (one centred row in a 22 pt strip under it). It takes
  effect as you click; an external display always shows the pill.
- The strip is drawn as the notch outline (`NotchShape`), not a rectangle. Its
  tuning knobs are constants in `Sources/BrowKit/Panel/NotchGeometry.swift` —
  `flare` (concave top corners, 6), `collapsedBottomRadius` (12),
  `expandedBottomRadius` (18), `wingWidth` (96), `belowStripHeight` (22). They are
  meant to be tuned by eye against the physical bezel; no screenshot can show it.
- Design: `docs/design/specs/2026-09-16-brow-design.md`, and
  `docs/design/specs/2026-09-17-brow-freshness-and-notch-design.md`.

Toolchain note: if `swift`/`git` abort with the Xcode license message, either
accept it (`sudo xcodebuild -license accept`) or `source Scripts/xcode-env.sh`
and run tests with `Scripts/test.sh` (see the comments in both scripts).

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

Since the AppleScript fallback (`CmuxAppleScript`), a socket denial is also
self-healing: Grove switches to driving cmux through its AppleScript
dictionary (one-time macOS consent dialog: System Settings > Privacy &
Security > Automation > Grove > cmux) and silently returns to the socket once
it accepts Grove again. Workspaces created via the fallback keep cmux's
cwd-derived tab title (the dictionary has no rename), and
`Scripts/build-app.sh` signs with a stable development identity so the
automation grant survives rebuilds.

### cmux diagnostic probe

`Grove.app` ships a hidden diagnostic flag that runs the exact production cmux
call path (ping, ensure-running, list, create + close a probe workspace —
exercising BOTH the socket backend and the AppleScript fallback) WITHOUT the
error-swallowing the UI does, and writes a step-by-step report (environment,
executable resolution, per-step stdout/stderr/error, raw-socket denial check,
active backend):

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
  the fixture PNGs (one per `SnapshotScene`) without starting the app — see `docs/snapshot-testing.md`
  for the workflow and the ImageRenderer caveats.
- Config lives at `~/Library/Application Support/Grove/config.json`
  (atomic writes, corrupt files are quarantined with a banner).
