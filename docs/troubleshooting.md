# Troubleshooting

## "cmux unavailable" although cmux is running

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

## cmux diagnostic probe

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

