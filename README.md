English · [Русский](README.ru.md) · [简体中文](README.zh-CN.md)

# Grove

**Grove is now part of [Brow](https://github.com/efim0v/brow).** From Brow 0.4.0, Grove's workspaces of git worktrees for parallel Claude Code sessions across several repositories run inside Brow, as Workspaces.

```sh
brew install --cask efim0v/tap/brow
```

Or download **[Brow.zip](https://github.com/efim0v/brow/releases/latest/download/Brow.zip)** · macOS 26 or later, Apple silicon · [install notes](https://github.com/efim0v/brow#install)

## What moved where

- **Workspaces** opens from Brow's item in the menu bar, the notch with two dots, and from the stacked-squares button in the notch panel: projects, workspaces, sessions, **Resume as…**, **Migrate to…**, **Share**, the commit graph and the code statistics.
- **Your projects, accounts and settings come along by themselves.** Brow finds Grove's `config.json` in `~/Library/Application Support/Grove` and turns Workspaces on with it. Nothing moves, and the status lines Grove captured keep working.
- **The command-line tool is `brow`**, with `grove` kept as a second name, so your scripts keep working: `brew install efim0v/tap/brow-cli`, after `brew uninstall grove-cli` if you have Grove's.
- **Grove.app can go.** Quit it first: while it runs, Workspaces waits and offers **Quit Grove**, so the two never write the same files. Then delete it, or run `brew uninstall --cask grove` without `--zap`, which would move the folder Brow now uses to the Trash. If Grove was in your Login Items, turn on **Launch at login** in Brow instead.

[Coming from Grove](https://github.com/efim0v/brow#coming-from-grove) says what else changes, such as the notch reading every account's limits, which Grove never did. The website is [efimov.page/brow](https://efimov.page/brow/).

The last Grove release, [0.2.2](https://github.com/efim0v/grove/releases/tag/0.2.2), stays available for reference, and so does the code in this repository. To remove Grove without moving to Brow, follow [the uninstall steps in its README](https://github.com/efim0v/grove/blob/0.2.2/README.md#uninstall).

## License

[GNU GPL v3](LICENSE). Version 0.2.0 and earlier were released under the MIT License.
