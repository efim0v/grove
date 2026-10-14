# Security policy

Grove handles things worth protecting. It edits Claude Code's configuration, links and copies session transcripts between accounts, and runs git, Claude Code, cmux and your own hook commands. `GroveCore`, the library in this repository, also holds the code Brow uses to read Claude Code's sign-in tokens.

## Supported versions

| Version | Supported |
| --- | --- |
| 0.2.x | Yes |

Fixes ship in a new release. Please check that the problem still happens on the latest release or on `main`.

## Reporting a vulnerability

Please do not report a security problem in a public issue, discussion or pull request.

Use GitHub's private reporting instead: **[Report a vulnerability](https://github.com/efim0v/grove/security/advisories/new)**. The report stays private between you and the maintainer until an advisory is published. If you can't use GitHub, email a.efimov@mizzle.studio.

A useful report says:

- the Grove version (shown at the bottom of the panel) and the macOS version;
- what an attacker needs (a crafted repository or branch name, a file planted in an account folder, another user on the same Mac) and what they get;
- the steps or a proof of concept, and whether the problem is in the app, the `grove` command-line tool or `GroveCore`.

## In scope

The code in this repository, in particular:

- **Edits to Claude Code's files.** At launch Grove points `statusLine.command` in each account's `settings.json` at a wrapper script in `~/Library/Application Support/Grove/bin`, unless that account's monitoring was stopped on the Accounts screen. The wrapper saves what Claude Code hands the status line under `<account>/grove/usage/`. Before it starts a session, Grove marks the account folder as onboarded in its `.claude.json`. **Migrate to…** merges the target account's `.claude.json`, `settings.json` and plugin registries.
- **Session data.** Linking an account turns its `file-history`, `tasks` and `session-env` directories, and `projects/<workspace>`, into symbolic links into `~/.claude`. The transcript mirror keeps hard links to every transcript under `~/.claude/grove/transcripts/`, and migration copies a session from one account folder to another.
- **Commands Grove runs.** git, `claude`, the cmux command-line tool, AppleScript for cmux and Terminal, and the post-create hooks set for a project, with paths, branch names and workspace names among their arguments. Grove can start a session with `--dangerously-skip-permissions` when the launch sheet or the project asks for it. It also reads cmux's socket password from `~/.config/cmux/cmux.json` and passes it on to cmux.
- **Credential code in `GroveCore`.** The Grove app never reads Claude Code's credentials. Brow does, through `GroveCore`: `ClaudeCredentials` reads each account's OAuth token from the login Keychain (or a legacy `.credentials.json`), the OAuth clients send it to `api.anthropic.com`, and `TokenKeeper` runs `claude` in the account's folder to keep the token fresh. A token that ends up anywhere else, such as on disk, in a log or in another request, is a vulnerability even if it shows up in Brow.

Examples of what to report:

- a repository, branch or workspace name that makes Grove run a command or write outside the workspace;
- Grove following a symbolic link out of an account folder and changing or deleting files there;
- another user on the Mac being able to read your sessions through a file or folder Grove created;
- a session started with `--dangerously-skip-permissions` when neither the launch sheet nor the project asked for it.

## Out of scope

- The release being signed ad hoc and not notarized. The [README](README.md#install) says so.
- Attacks that need code already running as your user account, which can read everything Grove can.
- Vulnerabilities in Claude Code itself (report them to Anthropic as its [security policy](https://github.com/anthropics/claude-code/security/policy) describes), or in cmux, git or macOS.
- Bugs that lose or damage data with no attacker involved. Please report those as regular issues.

## What happens next

Grove has one maintainer, so replies are not instant. The aim is to acknowledge a report within 7 days and to keep you updated in the advisory until it is resolved. How long a fix takes depends on the problem. Once the fix is released, the advisory is published and credits you, unless you would rather not be named.
