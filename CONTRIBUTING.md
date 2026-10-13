# Contributing to Grove

Thanks for helping. Grove has one maintainer, so this guide stays short: where to ask, what fits, how to build and test, and how to send a change.

- **Questions and setup help:** [Discussions → Q&A](https://github.com/efim0v/grove/discussions/categories/q-a).
- **Bugs:** [open an issue](https://github.com/efim0v/grove/issues/new/choose) with the bug report form. It asks for the versions, the setup and the log needed to track a problem down.
- **Ideas:** the feature request form, or [Discussions → Ideas](https://github.com/efim0v/grove/discussions/categories/ideas) to talk one through first.
- **Security problems:** never in a public issue. See [SECURITY.md](SECURITY.md).

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## What fits in Grove

Grove gives every feature a workspace of git worktrees across several repositories, starts Claude Code sessions in it, and moves sessions between Claude accounts. The commit graph, the code statistics and the `grove` command-line tool come with it. Fixes and improvements to any of that are welcome.

Some things live elsewhere:

- **Rate limits, the notch and one-click sign-in** are [Brow](https://github.com/efim0v/brow)'s job.
- **Problems with Claude Code itself** belong in [anthropics/claude-code](https://github.com/anthropics/claude-code/issues), and problems with cmux in [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux/issues). If Grove reports cmux as unavailable while cmux is running, read [`docs/troubleshooting.md`](docs/troubleshooting.md) first.

Three things to keep in mind:

- **`GroveCore` is shared with Brow.** Brow builds on this library, so a file Brow imports is shared code: keep Grove-only assumptions out of it. The on-disk contracts between the two apps change in both repositories together. [`docs/grove-and-brow.md`](docs/grove-and-brow.md) lists the shared files and the contracts.
- **Grove works on files Claude Code owns**: each account's `settings.json` and `.claude.json`, and its session folders. [What Grove does on your machine](README.md#what-grove-does-on-your-machine) has to stay true, so a change to what Grove writes there updates that section in the same pull request. Code that rewrites one of Claude Code's JSON files should go through `HotJSONFile`, which takes Claude Code's own lock and never overwrites a file that does not parse.
- **No third-party dependencies.** Grove has none, on purpose (see [COVERAGE.md](COVERAGE.md)).

For anything bigger than a small fix, open an issue first, so the approach is agreed before you spend time on code.

## Build, run and test

You need macOS 26 or later, Xcode with Swift 6.2 or newer, and git.

```sh
git clone https://github.com/efim0v/grove.git
cd grove

swift build                            # debug build: library, app and CLI
swift test                             # the whole suite, about two minutes
swift test -c release                  # the same suite, optimized
swift test --filter ConfigStoreTests   # one test class
```

- Both `swift test` and `swift test -c release` should pass before a pull request. The optimized run is not a formality: release builds have miscompiled Grove before (see `WorktreeScanResult` in `Sources/GroveCore/Services/WorkspaceService.swift`).
- The suite runs offline and needs no Claude account. Two tests are skipped unless you ask for them: `CmuxLiveTests` talks to a running cmux (`GROVE_LIVE_CMUX=1`), and `DemoScreenshotTests` renders the README screenshots (`DEMO_SCREENSHOTS_DIR`, see Development in the [README](README.md#development)).
- Some tests are timed. `ISODateParsingTests` gives 100,000 date parses one second, so it can fail on a heavily loaded Mac. Run it again on its own (`swift test --filter ISODateParsingTests`) before you dig in.
- New tests follow the existing pattern: fixtures, temporary directories and injected runners rather than the real `~/.claude`, the network or a running cmux. [COVERAGE.md](COVERAGE.md) describes how each layer is tested. `AppState` has test seams (`statuslineScriptDirOverride`, `accountsRootOverride`, `statsStoreDirOverride`) that keep a test from writing under your home folder.

To run the app and the command-line tool:

```sh
Scripts/build-app.sh       # release build -> dist/Grove.app; add --launch to open it
Scripts/dev-run.sh         # debug build, run from the terminal
swift run grove --help     # the command-line tool
swift run grove doctor     # which git, Claude Code and cmux it finds
```

- A build you run is Grove for real. At launch it points `statusLine` in each account's `settings.json` at its wrapper (unless that account's monitoring was stopped on the Accounts screen), and it reads and writes the same `~/Library/Application Support/Grove/config.json` as an installed copy. Grove does not check for a second copy of itself, so quit the installed one first (**Quit** at the bottom of the panel).
- Both scripts leave the app signed ad hoc unless `GROVE_SIGN_IDENTITY` names a code-signing identity of yours, such as `Apple Development: Name (TEAMID)`. With an ad hoc signature macOS forgets the Automation permission on every rebuild.
- `swift run GroveApp --snapshot /tmp/grove-snap` renders the app's screens to PNG from made-up data and exits without starting the app. It is the quickest way to look at a UI change; see [`docs/snapshot-testing.md`](docs/snapshot-testing.md).
- To watch the logs while you work:

  ```sh
  log stream --level info --predicate 'subsystem == "dev.artemefimov.grove" OR (process BEGINSWITH "Grove" AND subsystem == "dev.artemefimov.brow")'
  ```

  Grove logs under `dev.artemefimov.grove` (categories `menubar` and `perf`), at the info level, so they only show with `--level info`. `ProcessRunner` in `GroveCore` reports problems reading a command's output under Brow's identifier, `dev.artemefimov.brow`, which is what the second half of the filter picks up.

## Style

- Match the code around your change. There is no formatter or linter to run.
- Every target builds in the Swift 5 language mode (`Package.swift`). Don't add compiler warnings.
- Comments say why the code is the way it is, the way the note at the top of `Sources/GroveAppKit/GroveMenuBarApp.swift` explains why the menu-bar item is not a `MenuBarExtra`.
- New logic comes with tests.
- UI changes: re-render the affected screens with `--snapshot` and look at them. Those PNGs are throwaway and are not committed. If a change alters a screen the README shows, regenerate its screenshots with `DEMO_SCREENSHOTS_DIR="$PWD/docs/screenshots" swift test --filter DemoScreenshotTests`.
- Commit messages follow the history: `type(scope): summary`, such as `feat(grove): …`, `fix(core): …`, `test(snapshot): …` or `docs: …`. The summary says what changed for the person using Grove, in plain words, for example `fix(grove): one login is one account; a fresh folder launches signed in, in its own browser`.

## Pull requests

1. Fork the repository and branch off `main`.
2. Keep one change per pull request; a small one is easier to review.
3. Run `swift test` and `swift test -c release`.
4. Open the pull request and fill in the template: what changed and why, how you tested it, screenshots for UI changes, and whether the change touches code or contracts Brow depends on.
5. Link the issue it fixes, for example `Fixes #12`.

With one maintainer, a review can take a few days.

## License

Grove is licensed under the [GNU GPL v3](LICENSE). By sending a pull request you agree that your contribution is released under the same license.
