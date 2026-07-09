import Foundation

// MARK: - Pure JSON helpers for cross-account session migration
//
// All methods are pure (no FileManager, no Date()). They accept and return
// Foundation-decoded JSON (`[String: Any]`), the same representation produced
// by `JSONSerialization.jsonObject(with:options:)`.
//
// Bool/NSNumber caveat: JSONSerialization decodes JSON `true`/`false` as
// `NSNumber` backed by `__NSCFBoolean`. Swift's `as? Bool` cast succeeds on
// those. However, when we re-encode arrays for dedup comparison we use
// `JSONSerialization` which preserves the original type. Callers must not
// assume `as? Int` succeeds on a bool-valued NSNumber.

public struct SessionMigration: Sendable {

    // MARK: - 1. deepMergeJSON

    /// Recursively merge `source` INTO `target`, non-destructively:
    /// - nested dicts: recurse
    /// - arrays: union (source elements not already in target appended,
    ///   dedup by JSON encoding, order preserved)
    /// - scalars: target wins when key exists, else take source
    /// Never removes target keys.
    public static func deepMergeJSON(
        target: [String: Any],
        source: [String: Any]
    ) -> [String: Any] {
        var result = target
        for (key, sourceVal) in source {
            if let targetVal = result[key] {
                if let tDict = targetVal as? [String: Any],
                   let sDict = sourceVal as? [String: Any] {
                    result[key] = deepMergeJSON(target: tDict, source: sDict)
                } else if let tArr = targetVal as? [Any],
                          let sArr = sourceVal as? [Any] {
                    result[key] = unionArrays(target: tArr, source: sArr)
                }
                // scalar: target wins (do nothing)
            } else {
                result[key] = sourceVal
            }
        }
        return result
    }

    // MARK: - 2. mergeSettingsKeys

    /// Return a copy of `target` where only the specified `keys` are merged
    /// from `source`. Rules per key:
    /// - both dicts → deepMergeJSON
    /// - both arrays → union
    /// - target lacks key → copy source value
    /// - target has scalar → keep target (target-wins)
    /// All other target keys are untouched. Unlisted source keys are ignored.
    public static func mergeSettingsKeys(
        target: [String: Any],
        source: [String: Any],
        keys: [String]
    ) -> [String: Any] {
        var result = target
        for key in keys {
            guard let sourceVal = source[key] else { continue }
            if let targetVal = result[key] {
                if let tDict = targetVal as? [String: Any],
                   let sDict = sourceVal as? [String: Any] {
                    result[key] = deepMergeJSON(target: tDict, source: sDict)
                } else if let tArr = targetVal as? [Any],
                          let sArr = sourceVal as? [Any] {
                    result[key] = unionArrays(target: tArr, source: sArr)
                }
                // scalar: target wins (do nothing)
            } else {
                result[key] = sourceVal
            }
        }
        return result
    }

    // MARK: - 3. mergeClaudeProjectEntry

    /// Return a copy of `targetHomeJSON` (a decoded `.claude.json`) where
    /// `projects[cwd]` is `deepMergeJSON(target: existing or {}, source: sourceEntry)`.
    /// Creates the `projects` dict / `projects[cwd]` if absent.
    /// All other top-level keys and other projects are untouched.
    public static func mergeClaudeProjectEntry(
        targetHomeJSON: [String: Any],
        sourceEntry: [String: Any],
        cwd: String
    ) -> [String: Any] {
        var result = targetHomeJSON
        var projects = (result["projects"] as? [String: Any]) ?? [:]
        let existing = (projects[cwd] as? [String: Any]) ?? [:]
        projects[cwd] = deepMergeJSON(target: existing, source: sourceEntry)
        result["projects"] = projects
        return result
    }

    // MARK: - 4. repointPluginInstallPaths

    /// Return a copy of `installedPlugins` (decoded `installed_plugins.json`)
    /// where every `installPath` that starts with `fromConfigDir` has that
    /// prefix replaced by `toConfigDir` (once, at the leading position only).
    /// Missing/oddly-shaped entries are skipped gracefully.
    public static func repointPluginInstallPaths(
        installedPlugins: [String: Any],
        fromConfigDir: String,
        toConfigDir: String
    ) -> [String: Any] {
        var result = installedPlugins
        guard var plugins = result["plugins"] as? [String: Any] else {
            return result
        }
        for (pluginKey, pluginVal) in plugins {
            guard let entries = pluginVal as? [[String: Any]] else { continue }
            let repointed: [[String: Any]] = entries.map { entry in
                var e = entry
                if let path = e["installPath"] as? String,
                   path.hasPrefix(fromConfigDir) {
                    // Replace only the leading prefix, once
                    let suffix = String(path.dropFirst(fromConfigDir.count))
                    e["installPath"] = toConfigDir + suffix
                }
                return e
            }
            plugins[pluginKey] = repointed
        }
        result["plugins"] = plugins
        return result
    }

    // MARK: - Private helpers

    /// Array union: append elements from `source` not already present in `target`.
    /// Deduplication is by equality of JSON encoding (handles nested dicts/arrays).
    private static func unionArrays(target: [Any], source: [Any]) -> [Any] {
        let targetFingerprints = target.compactMap { jsonFingerprint($0) }
        var result = target
        for element in source {
            guard let fp = jsonFingerprint(element) else {
                result.append(element)
                continue
            }
            if !targetFingerprints.contains(fp) {
                result.append(element)
            }
        }
        return result
    }

    /// Stable JSON encoding of a value for equality comparison.
    private static func jsonFingerprint(_ value: Any) -> String? {
        // Wrap scalars in an array so JSONSerialization can encode them
        guard JSONSerialization.isValidJSONObject(["v": value]) else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["v": value],
            options: .sortedKeys
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
