import Foundation

/// Expands a leading "~" to the current user's home directory; other paths pass through unchanged.
public func expandTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

/// POSIX single-quote shell quoting: wraps in single quotes; an embedded
/// single quote becomes the '\'' sequence (close quote, escaped quote, reopen).
public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
