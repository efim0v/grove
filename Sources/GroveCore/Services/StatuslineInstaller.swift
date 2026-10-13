import Foundation

/// Installs/uninstalls a grove-owned statusline wrapper for ONE account
/// (spec §C.1, decision D3). Takes explicit STRING paths only: tests inject a
/// temp `scriptDir` (app-support bin) and operate on a temp `<configDir>/settings.json`
/// — NEVER the user's real settings. The wrapper tees Claude's statusline stdin into
/// `<configDir>/grove/usage/<session_id>.json` (timestamped) then execs the saved
/// original, so the user's statusline is unchanged. Install is opt-in, reversible.
public struct StatuslineInstaller: Sendable {
    /// Directory the wrapper script is shipped into. Production passes
    /// `~/Library/Application Support/Grove/bin`; tests pass a temp dir.
    public let scriptDir: String
    public init(scriptDir: String) { self.scriptDir = scriptDir }

    /// Per-account wrapper path inside `scriptDir`: ONE script per
    /// `CLAUDE_CONFIG_DIR`, keyed by the canonicalized config dir, so every
    /// account's `settings.json` points at its OWN wrapper carrying its own baked
    /// `GROVE_USAGE_DIR`/`GROVE_ORIG`. A single shared script would have its baked
    /// env clobbered whenever a second account installs — breaking multi-account
    /// monitoring (account A would write to B's usage dir and run B's original).
    public func scriptPath(forConfigDir configDir: String) -> String {
        scriptDir + "/grove-statusline-" + ClaudeService.mangle(canonicalPath(configDir)) + ".sh"
    }

    /// Writes the wrapper (idempotent, chmod +x), reads `<configDir>/settings.json`,
    /// SAVES the prior `statusLine.command` (nil when absent OR already the wrapper),
    /// and repoints `statusLine.command` at the wrapper. Returns the saved original
    /// for `AccountConfig.savedStatusline`. Re-install never clobbers the saved
    /// original with the wrapper path.
    ///
    /// `settings.json` is merged through `HotJSONFile`: under Claude Code's lock,
    /// through a symlink, keeping the file's mode, and not written at all when nothing
    /// changes. A file that exists but doesn't parse (a `//` comment, a half-written
    /// save) is left as it is and the install throws: writing back `statusLine` alone
    /// would drop the account's permissions, hooks and env.
    @discardableResult
    public func install(configDir: String) throws -> String? {
        try StatuslineInstaller.requireConfigDir(configDir)
        let settingsPath = configDir + "/settings.json"
        let scriptPath = self.scriptPath(forConfigDir: configDir)
        // The command MUST be shell-quoted: Claude Code runs statusLine.command via
        // `sh -c`, and the production scriptDir (~/Library/Application Support/Grove/bin)
        // contains a SPACE. An unquoted path breaks ("…/Library/Application: not found",
        // exit 127) so the wrapper never runs and no usage/limit snapshot is ever
        // written — the cause of all-zero limits in the app.
        let quotedCommand = shellQuote(scriptPath)
        try? FileManager.default.createDirectory(
            atPath: scriptDir, withIntermediateDirectories: true)
        let usageDir = configDir + "/grove/usage"

        var original: String?
        try HotJSONFile.update(path: settingsPath) { existing in
            // Determine the true original command BEFORE we overwrite anything. On a
            // re-install the existing `statusLine.command` is already our (bare) wrapper
            // path; the real original is baked into the previously-shipped script as
            // `GROVE_ORIG='…'`. On first install the existing command itself is the
            // original.
            let currentCommand = (existing["statusLine"] as? [String: Any])?["command"] as? String
            if let current = currentCommand {
                // Already our wrapper? Accept the quoted form AND the legacy bare path
                // written before the quoting fix (so a re-install migrates it cleanly).
                if current == quotedCommand || current == scriptPath {
                    // Recover the real original baked into the previously-shipped script.
                    original = StatuslineInstaller.bakedOriginal(inScriptAt: scriptPath)
                } else {
                    original = current
                }
            } else {
                original = nil
            }

            // Ship the wrapper script with this account's usage dir + original baked in
            // (idempotent, chmod +x) before settings.json points at it. Only reached with a
            // settings.json that parsed, so a refused install leaves a wrapper already in
            // use, and the original baked into it, as they are. The env defaults live in
            // the per-account script so `statusLine.command` can stay the bare script path.
            let script = StatuslineInstaller.scriptSource(usageDir: usageDir, original: original)
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptPath)

            // Repoint settings at the shell-quoted wrapper path (handles the space).
            var settings = existing
            settings["statusLine"] = ["type": "command", "command": quotedCommand]
            return settings
        }
        return original
    }

    /// Restores `statusLine.command` to `savedStatusline`, or REMOVES the statusLine
    /// key when nil. Leaves the shipped script in place (harmless). Merged through
    /// `HotJSONFile` like `install`: a settings.json that doesn't parse is left as it
    /// is and this throws.
    public func uninstall(configDir: String, savedStatusline: String?) throws {
        try StatuslineInstaller.requireConfigDir(configDir)
        let settingsPath = configDir + "/settings.json"
        try HotJSONFile.update(path: settingsPath) { existing in
            var settings = existing
            if let saved = savedStatusline {
                settings["statusLine"] = ["type": "command", "command": saved]
            } else {
                settings.removeValue(forKey: "statusLine")
            }
            return settings
        }
    }

    /// `HotJSONFile` creates a missing parent folder. An account folder that isn't there
    /// (an alias folder the user deleted) isn't the installer's to recreate, so install
    /// and uninstall fail on it, as the plain write did. Callers create a new account's
    /// folder before they install.
    private static func requireConfigDir(_ configDir: String) throws {
        guard FileManager.default.fileExists(atPath: configDir) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: configDir])
        }
    }

    // MARK: - wrapper script (per-account env baked in)

    /// The shipped wrapper for one account: the generic `wrapperScript` with this
    /// account's `GROVE_USAGE_DIR` and `GROVE_ORIG` baked in as defaults (so the bare
    /// script path in `settings.json` needs no env). `GROVE_ORIG` is shell-quoted so a
    /// re-install can parse the real original back out via `bakedOriginal(inScriptAt:)`.
    static func scriptSource(usageDir: String, original: String?) -> String {
        // Plain (top-level) shell assignments: single-quote quoting IS honored here,
        // so `bakedOriginal(inScriptAt:)` can parse the original back out on re-install.
        let bake = ""
            + "GROVE_USAGE_DIR=\(shellQuote(usageDir))\n"
            + "GROVE_ORIG=\(shellQuote(original ?? ""))\n"
            + "export GROVE_USAGE_DIR GROVE_ORIG\n"
        // Inject the baked defaults right after the shebang line of the generic script.
        let lines = wrapperScript.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.hasPrefix("#!") else {
            return bake + wrapperScript
        }
        let rest = lines.dropFirst().joined(separator: "\n")
        return String(first) + "\n" + bake + rest
    }

    /// Recovers the `GROVE_ORIG` baked into a previously-shipped script (the `: "${...}"`
    /// default-assignment line). Returns nil when the file is missing, has no marker, or
    /// the baked original is empty (meaning "no original to restore").
    static func bakedOriginal(inScriptAt path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let value = extractGroveOrigDefault(from: String(line)) else { continue }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Parses the `original` from a baked assignment line of the form
    /// `GROVE_ORIG='…'` where `…` is POSIX single-quoted (with `'\''` escapes).
    static func extractGroveOrigDefault(from line: String) -> String? {
        let marker = "GROVE_ORIG="
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.hasPrefix(marker) else { return nil }
        var rest = trimmed[trimmed.index(trimmed.startIndex, offsetBy: marker.count)...]
        // The baked value is a shell-quoted token starting with a single quote.
        guard let firstQuote = rest.firstIndex(of: "'") else { return nil }
        rest = rest[rest.index(after: firstQuote)...]
        var out = ""
        while let q = rest.firstIndex(of: "'") {
            out += rest[rest.startIndex..<q]
            // `'\''` is an escaped single quote inside the single-quoted token.
            let after = rest.index(after: q)
            if after < rest.endIndex, rest[after] == "\\",
               rest.index(after: after) < rest.endIndex,
               rest[rest.index(after: after)] == "'" {
                let close = rest.index(after: rest.index(after: after))
                if close < rest.endIndex, rest[close] == "'" {
                    out += "'"
                    rest = rest[rest.index(after: close)...]
                    continue
                }
            }
            return out
        }
        return out
    }

    /// The wrapper script source. It must: read stdin once into a var; extract
    /// session_id with a tiny grep/sed (no jq dependency — Claude Code ships none);
    /// atomically write the trimmed JSON + a capturedAt stamp to
    /// $GROVE_USAGE_DIR/<session_id>.json; then exec the saved original ($GROVE_ORIG)
    /// feeding it the SAME stdin; degrade to a bare passthrough on any error.
    static let wrapperScript: String = ##"""
    #!/bin/sh
    # grove-statusline wrapper (managed by Grove; do not edit).
    # Reads Claude Code statusline stdin, snapshots it for Grove, then calls the
    # user's original command through with the same stdin. Passthrough on any error.
    set -e
    IN="$(cat)"
    DIR="${GROVE_USAGE_DIR:-}"
    if [ -n "$DIR" ]; then
      mkdir -p "$DIR" 2>/dev/null || true
      SID="$(printf '%s' "$IN" | sed -n 's/.*"session_id"[ ]*:[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
      [ -z "$SID" ] && SID="unknown"
      TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      TMP="$DIR/.$SID.tmp.$$"
      # Wrap the raw render with a capturedAt envelope; the raw keys stay readable.
      printf '{"capturedAt":"%s","raw":%s}' "$TS" "$IN" > "$TMP" 2>/dev/null && \
        mv -f "$TMP" "$DIR/$SID.json" 2>/dev/null || true
    fi
    if [ -n "${GROVE_ORIG:-}" ]; then
      printf '%s' "$IN" | /bin/sh -c "$GROVE_ORIG"
    fi
    """##
}
