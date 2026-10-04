# Grove and Brow — two utilities, one shared core

Grove and Brow are separate apps with separate jobs that share one picture of
"what a Claude account on this Mac is". They live in two repositories —
[grove](https://github.com/efim0v/grove) and [brow](https://github.com/efim0v/brow) —
and Brow depends on Grove's `GroveCore` library as a Swift package.

| | Grove | Brow |
|---|---|---|
| Job | Projects, worktrees, sessions; launching, sharing and **migrating** sessions across accounts | Every account's rate limits in the notch; one-click sign-in of a new account |
| UI | Menu-bar tree → panel | Notch readouts → hover panel |
| Targets | `GroveCore`, `GroveAppKit`, `GroveApp`, `grove-cli` | `BrowKit`, `BrowApp` (+ `GroveCore`) |
| Bundle id | `dev.artemefimov.grove3` | `dev.artemefimov.brow` |
| Repository | [efim0v/grove](https://github.com/efim0v/grove) | [efim0v/brow](https://github.com/efim0v/brow) |
| Build | `Scripts/build-app.sh` → `dist/Grove.app` | `Scripts/build-brow.sh` → `dist/Brow.app` |
| Own state | `~/Library/Application Support/Grove/` | `~/Library/Application Support/Brow/` |
| Reads Claude's Keychain credentials | **never** | yes — the only one that does |

Each app works without the other. Together they cover the whole loop: Brow shows
which account has room, Grove moves the work there.

## Compile-time shape

```
            GroveCore            ← the one shared leaf, no dependencies
           /         \
   GroveAppKit      BrowKit      ← siblings; neither imports the other
        |              |
    GroveApp        BrowApp
    grove-cli
```

The graph is a clean Y. `BrowKit → GroveCore` is the only edge between the two
utilities, and no Grove target imports anything of Brow's.

What Brow takes from `GroveCore` (≈ 2.9k of its ≈ 10k lines):

- **Used by Brow only** — `AccountDirectory`, `ClaudeCredentials`, `TokenKeeper`,
  `OAuthUsageClient`, `OAuthProfileClient`, `RateLimitModel`, `UsagePacingLedger`.
- **Used by both** — `ProcessRunner`, `UsageReader` (statusline captures),
  `Paths.swift` (`accountKey`, `shellQuote`, `expandTilde`),
  `ClaudeService.ensureOnboarded`.

Everything else in `GroveCore` (git, cmux, workspaces, code stats, the shared
session store, the transcript mirror, session migration) is Grove's alone.

## Runtime contracts

The compile-time edge is thin; the real coupling is on disk. These are the
contracts — change one side and the other breaks silently, so change them together.

1. **`accountKey`** — first 8 hex of `sha256(<expanded config dir, no trailing slash>)`.
   One number, three users: Claude Code's Keychain item name
   (`Claude Code-credentials-<key>`), Grove's transcript mirror directory, and the
   Chrome profile directory. It is implemented **twice**: `GroveCore/Model/Paths.swift`
   in the grove repository and, in shell, `Resources/brow-browser.sh` in the brow
   repository. Keep them identical.
2. **Account folders** — `~/.claude` plus `~/.claude-accounts/*`. Brow creates
   `account-N` on sign-in; Grove creates named folders and adopts any it finds,
   Brow's included. Both stamp a fresh folder with `ClaudeService.ensureOnboarded`.
3. **The browser router** — `Resources/brow-browser.sh`, shipped inside
   `Brow.app/Contents/Resources/brow-browser`. It opens a URL in the account's own
   browser profile (`~/Library/Application Support/Brow/browser-profiles/<accountKey>`).
   Brow uses it from its own bundle; Grove locates it **inside the installed
   Brow.app** (`AppState.locateBrowserRouter`: bundle id, then `/Applications/Brow.app`)
   and passes it as `BROWSER=` to every session it launches. Without Brow installed
   Grove launches sessions with the system browser — nothing else changes.
4. **Statusline captures** — `<configDir>/grove/usage/<session>.json`, written by
   the statusline wrapper **Grove** installs (`StatuslineInstaller`), read by both
   through `UsageReader`. Brow's freshest numbers exist because Grove installed
   the wrapper.
5. **The pacing ledger** — `~/Library/Application Support/Grove/oauth-usage-ledger.json`
   (`FileUsagePacingLedger`). Under Grove's folder for historical reasons; today only
   Brow reads and writes it.

There is no IPC between the apps: no URL scheme, XPC, distributed notifications or
shared `UserDefaults` suite.

## Hot migration and files a running `claude` owns

Grove migrates a session into an account **while that account is in use**. The
target's `.claude.json`, `settings.json` and plugin registries are merged through
`HotJSONFile`: Claude Code's own `<file>.lock` (proper-lockfile protocol), a
compare-before-swap that redoes the merge if the file changed underneath, no write
at all when nothing changes, and a hard refusal to overwrite a file that does not
parse. Transcripts are copied into the target, never hardlinked across accounts —
hardlinks are reserved for the transcript mirror, where exactly one writer exists.

What is still refused, deliberately: anything that would give **one session** two
writers (sharing a session that is running; resuming under account B a session
that is live under account A).

## Two repositories, one core

The apps are published separately, and `GroveCore` stays in the grove repository:
Brow's `Package.swift` pulls it in as a dependency pinned to a Grove release.

That makes the runtime contracts above a versioned protocol. Three of the five are
enforced only by the two sides agreeing, so a change to one of them is a change in
both repositories: land it in grove, tag a release, then raise the version Brow
depends on and adjust Brow in the same commit.

What would make the boundary cleaner:

- Extract a `ClaudeAccountsKit` library (working name) from `GroveCore`: the
  Brow-only and used-by-both files listed above, with their tests. `GroveCore` and
  `BrowKit` both depend on it, and "GroveCore" means Grove again.
- Move the browser router there as a resource of the shared library, so Grove
  carries its own copy instead of reaching into `/Applications/Brow.app`, and add
  a test pinning the shell `accountKey` to the Swift one.
- Give shared loggers a neutral subsystem (`ProcessRunner` and `TokenKeeper`
  currently log under Brow's bundle id even when Grove runs them).

Until then the rule is: a file Brow imports is shared code — keep Grove-only
assumptions out of it.
