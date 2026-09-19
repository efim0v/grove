import Foundation
import CryptoKit

/// Expands a leading "~" to the current user's home directory; other paths pass through unchanged.
public func expandTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

/// Filesystem-safe identity for an account's config dir: first 8 hex of
/// sha256(expanded dir, no trailing slash). Same scheme Claude Code uses to key
/// its Keychain item, so credential lookup and the transcript mirror agree on one
/// identity per account.
public func accountKey(_ configDir: String) -> String {
    var dir = (configDir as NSString).expandingTildeInPath
    if dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
    let hex = SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(8))
}

/// POSIX single-quote shell quoting: wraps in single quotes; an embedded
/// single quote becomes the '\'' sequence (close quote, escaped quote, reopen).
public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Foundation-canonical form of a path so comparisons survive macOS
/// /var -> /private/var symlinks: git and live processes report realpaths
/// (/private/var/...), resolvingSymlinksInPath() maps both forms to the
/// /var/... spelling.
public func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: expandTilde(path)).resolvingSymlinksInPath().path
}

/// `~/.claude` — the one config dir Claude Code treats specially. With
/// `CLAUDE_CONFIG_DIR` UNSET the CLI keeps its login in the Keychain item
/// `Claude Code-credentials`; with the variable SET — even to this very path — it
/// uses the hashed item `Claude Code-credentials-<accountKey>` instead, which is a
/// different, normally empty login. So every command for the default dir must run
/// with the variable absent, never with it pointing at `~/.claude`.
public func isDefaultClaudeDir(_ configDir: String) -> Bool {
    var dir = (configDir as NSString).expandingTildeInPath
    if dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
    return dir == NSHomeDirectory() + "/.claude"
}
