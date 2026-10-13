# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] - 2026-10-13

A source release: Brow 0.2.1 takes `GroveCore` from this tag. There is no `Grove.zip` or `grove-cli.zip` for 0.2.1; the next prebuilt Grove is 0.2.2.

### Added

- An Install section in the README for the prebuilt `Grove.zip`. It covers the first launch, which macOS blocks because the build is not notarized, and names the release's other two files: `grove-cli.zip` with the command-line tool, and `SHA256SUMS.txt` for checking the downloads. A download link sits at the top of the README.
- `grove --version` and `grove version`, which print the version.
- Homebrew: `brew install --cask efim0v/tap/grove` installs the app and `brew install efim0v/tap/grove-cli` the command-line tool, from the [efim0v/homebrew-tap](https://github.com/efim0v/homebrew-tap) tap. As with the zip, macOS blocks the app's first launch.
- A section in the README on how Grove's workspaces differ from Claude Code's own `claude --worktree`.
- An Uninstall section in the README: giving each account its status line back, removing the app and the files and folders Grove creates, and turning linked accounts back into separate folders.
- The README's "What Grove does on your machine" now also says that transcripts deleted by Claude Code's own `cleanupPeriodDays` cleanup come back from the transcript mirror until they are 90 days old by default, and that the mirror can be turned off; that Grove marks Claude Code's first-run setup as done in account folders other than `~/.claude`; and that your own status line keeps working behind Grove's wrapper.
- The README in Russian (`README.ru.md`) and Simplified Chinese (`README.zh-CN.md`), with a language switcher at the top of all three READMEs.
- A landing page at [efim0v.github.io/grove](https://efim0v.github.io/grove/), published from `site/` with GitHub Pages.
- A contributing guide (`CONTRIBUTING.md`), a code of conduct (the Contributor Covenant 2.1), a security policy (`SECURITY.md`) that explains how to report a vulnerability privately, issue forms for bug reports and feature requests, and a pull request template.
- Continuous integration: GitHub Actions builds Grove on macOS 26 for every pull request and every push to `main`, and runs the tests in both debug and release builds.

### Changed

- Grove is now licensed under the [GNU GPL v3](LICENSE). Version 0.2.0 and earlier were released under the MIT License.
- `grove doctor` exits with status 1 when it can't run git or `claude`, so a script can use it as a check. Before, it exited 0 whatever it found. cmux is recommended, not required, because sessions can also open in Terminal: a missing cmux shows as `not found (optional)` and doesn't fail the check. In `--json` output each tool now has a `required` field.
- `GroveCore`'s usage and profile requests, the ones Brow makes, go through their own ephemeral session, so nothing about them is cached on disk. The first request after launch empties the app's shared URL cache, which earlier builds used for them.

### Fixed

- The storage diagram in the README now renders on GitHub. Before, GitHub showed an error in its place: one of the diagram's subgraphs had the id `default`, which is a reserved word in Mermaid.
- `grove doctor` no longer reports git as found when the `/usr/bin/git` shim has no developer directory to run git from. The shim then exits 1 and prints nothing on stdout, which `doctor` used to show as `✓ git  (version unknown)`. A tool whose `--version` fails now counts as missing.
- The README no longer says that cmux is the only way to start a session. cmux is recommended; the launch sheet can open a session in Terminal.app instead, and the README says which buttons go through the sheet.
- `Scripts/test.sh` prints `BUILD FAILED` and exits with status 1 when the build fails. Before, it went on to run the test bundles left from an earlier build and could exit 0.
- `Scripts/coverage.sh` finds the test bundles that Swift 6.4 builds, under either of SwiftPM's build systems, and prints its coverage report. Before, it stopped right after the tests without printing any numbers.

## [0.2.0] - 2026-10-05

First public release: git-worktree workspaces for running parallel Claude Code sessions on a product split across several repositories, as a macOS menu-bar app and a command-line tool.

### Added

- Workspaces: one directory per feature that holds a git worktree of each repository you choose, all on the same branch. Claude Code starts in that directory. Creating a workspace runs `git worktree add` in each repository, names the branch from a template (`feat/{name}` by default), seeds the shared files you list, such as `CLAUDE.md`, and runs your post-create hooks.
- Stacked workspaces: a workspace can be forked from another workspace's branch instead of the base branch.
- Launching Claude Code in cmux or in Terminal. Each new or resumed session can pick its own account, model and effort, and a project can set defaults for them.
- Moving a session between Claude accounts. **Resume as…** continues it under another account without copying anything, because linked accounts share their session files through symbolic links into `~/.claude`. **Migrate to…** copies a session into another account (transcript, memory, file history, tasks), even while that account is in use. **Share** moves a session into the shared store so every linked account can see it.
- A transcript mirror, on by default: hard links under `~/.claude/grove/transcripts/` that restore a transcript if it disappears from an account. Entries are kept for 90 days and up to 500 MB by default; **Purge** deletes a transcript for good.
- **Graph**: the commit graph of a repository with its branches, remotes and tags. From a branch you can create a workspace, or open Claude Code in its worktree.
- **Stats**: lines of code across the project, with totals, a language breakdown and growth over time stacked by repository.
- The `grove` command-line tool: `scan`, `workspaces`, `sessions`, `create`, `graph` and `doctor`, each with `--json`.
- Prebuilt downloads for macOS 26 or later on Apple silicon: `Grove.zip` with the app and `grove-cli.zip` with the command-line tool, plus `SHA256SUMS.txt` to verify them. The app is signed ad hoc and not notarized.

[Unreleased]: https://github.com/efim0v/grove/compare/0.2.1...HEAD
[0.2.1]: https://github.com/efim0v/grove/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/efim0v/grove/releases/tag/0.2.0
