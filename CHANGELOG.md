# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- An Install section in the README for the prebuilt `Grove.zip`. It covers the first launch, which macOS blocks because the build is not notarized, and names the release's other two files: `grove-cli.zip` with the command-line tool, and `SHA256SUMS.txt` for checking the downloads. A download link sits at the top of the README.

### Changed

- Grove is now licensed under the [GNU GPL v3](LICENSE). Version 0.2.0 and earlier were released under the MIT License.

### Fixed

- The storage diagram in the README now renders on GitHub. Before, GitHub showed an error in its place: one of the diagram's subgraphs had the id `default`, which is a reserved word in Mermaid.

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

[Unreleased]: https://github.com/efim0v/grove/compare/0.2.0...HEAD
[0.2.0]: https://github.com/efim0v/grove/releases/tag/0.2.0
