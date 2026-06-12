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

    /// Filename of the shipped wrapper inside `scriptDir`.
    public static let scriptName = "grove-statusline.sh"

    public var scriptPath: String { scriptDir + "/" + StatuslineInstaller.scriptName }

    /// Writes the wrapper (idempotent, chmod +x), reads `<configDir>/settings.json`,
    /// SAVES the prior `statusLine.command` (nil when absent OR already the wrapper),
    /// and repoints `statusLine.command` at the wrapper. Returns the saved original
    /// for `AccountConfig.savedStatusline`. Re-install never clobbers the saved
    /// original with the wrapper path.
    @discardableResult
    public func install(configDir: String) throws -> String? {
        // Determine the true original command BEFORE we overwrite anything. On a
        // re-install the existing `statusLine.command` is already our (bare) wrapper
        // path; the real original is baked into the previously-shipped script as
        // `GROVE_ORIG='…'`. On first install the existing command itself is the
        // original.
        let settingsPath = configDir + "/settings.json"
        var settings = StatuslineInstaller.readSettings(at: settingsPath)
        let currentCommand = (settings["statusLine"] as? [String: Any])?["command"] as? String

        let original: String?
        if let current = currentCommand {
            if current == scriptPath {
                // Already the wrapper: recover the real original baked into the
                // previously-shipped script (nil when there was none).
                original = StatuslineInstaller.bakedOriginal(inScriptAt: scriptPath)
            } else {
                original = current
            }
        } else {
            original = nil
        }

        // Ship the wrapper script with this account's usage dir + original baked in
        // (idempotent, chmod +x). The env defaults live in the per-account script so
        // `statusLine.command` can stay the bare script path.
        try? FileManager.default.createDirectory(
            atPath: scriptDir, withIntermediateDirectories: true)
        let usageDir = configDir + "/grove/usage"
        let script = StatuslineInstaller.scriptSource(usageDir: usageDir, original: original)
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        // Repoint settings at the bare wrapper path.
        settings["statusLine"] = ["type": "command", "command": scriptPath]
        try StatuslineInstaller.writeSettings(settings, to: settingsPath)
        return original
    }

    /// Restores `statusLine.command` to `savedStatusline`, or REMOVES the statusLine
    /// key when nil. Leaves the shipped script in place (harmless).
    public func uninstall(configDir: String, savedStatusline: String?) throws {
        let settingsPath = configDir + "/settings.json"
        var settings = StatuslineInstaller.readSettings(at: settingsPath)
        if let saved = savedStatusline {
            settings["statusLine"] = ["type": "command", "command": saved]
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try StatuslineInstaller.writeSettings(settings, to: settingsPath)
    }

    // MARK: - settings.json IO

    /// Reads `settings.json` as a mutable dictionary; empty `{}` when absent or unparseable.
    private static func readSettings(at path: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return [:] }
        return dict
    }

    private static func writeSettings(_ settings: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
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
