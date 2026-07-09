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

// MARK: - MigrateReport

/// Collects outcomes of `copySessionData`: paths copied, skipped (already present),
/// and any issues (non-fatal errors). Sendable + Equatable for test assertions.
public struct MigrateReport: Sendable, Equatable {
    public var copied:  [String] = []
    public var skipped: [String] = []
    public var issues:  [String] = []
    public init() {}
}

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

    // MARK: - 5. copySessionData

    /// Phase-A filesystem copy for cross-account session migration.
    ///
    /// Copies every data footprint item for `sessionId`/`cwd` from `fromConfigDir`
    /// to `toConfigDir`. Non-destructive: never moves, renames, or deletes source
    /// items. Idempotent: items already present at the target are skipped (recorded
    /// in `report.skipped`). Collects errors in `report.issues` without throwing.
    ///
    /// Items copied (relative to each configDir unless noted):
    ///   1. `projects/<mangled>/<sessionId>.jsonl`        — transcript
    ///   2. `projects/<mangled>/<sessionId>/`             — aux dir (recursive)
    ///   3. `projects/<mangled>/memory/`                  — merge-copy (no overwrite)
    ///   4. `file-history/<sessionId>/`                   — recursive copy
    ///   5. `tasks/<sessionId>/`                          — recursive copy
    ///   6. `session-env/<sessionId>/`                    — recursive copy
    ///   7. `grove/usage/<sessionId>.json`                — single file
    ///
    /// Mirror fallback (item 1): if the live transcript is absent at source, the
    /// method tries `<mirrorRoot>/<fromAccountKey>/<mangled>/<sessionId>.jsonl`.
    /// If neither exists, an issue is recorded and the remaining items are still
    /// copied.
    public static func copySessionData(
        sessionId: String,
        cwd: String,
        fromConfigDir: String,
        toConfigDir: String,
        mirrorRoot: String?,
        fromAccountKey: String
    ) -> MigrateReport {
        var report = MigrateReport()
        let fm = FileManager.default
        let mangled = ClaudeService.mangle(cwd)

        // 1. Transcript (.jsonl)
        let transcriptRel = "projects/\(mangled)/\(sessionId).jsonl"
        let liveSrc = fromConfigDir + "/" + transcriptRel
        let transcriptDst = toConfigDir + "/" + transcriptRel
        var transcriptSrc: String? = fm.fileExists(atPath: liveSrc) ? liveSrc : nil
        if transcriptSrc == nil, let mirror = mirrorRoot {
            let mirrorSrc = "\(mirror)/\(fromAccountKey)/\(mangled)/\(sessionId).jsonl"
            if fm.fileExists(atPath: mirrorSrc) { transcriptSrc = mirrorSrc }
        }
        if let src = transcriptSrc {
            copySingleFile(src: src, dst: transcriptDst, report: &report)
        } else {
            report.issues.append("transcript unavailable: \(sessionId).jsonl not found at source or mirror")
        }

        // 2. Aux dir  projects/<mangled>/<sessionId>/
        let auxSrc = fromConfigDir + "/projects/\(mangled)/\(sessionId)"
        let auxDst = toConfigDir + "/projects/\(mangled)/\(sessionId)"
        copyDir(src: auxSrc, dst: auxDst, merge: false, report: &report)

        // 3. Memory dir  projects/<mangled>/memory/  — merge (no overwrite)
        let memorySrc = fromConfigDir + "/projects/\(mangled)/memory"
        let memoryDst = toConfigDir + "/projects/\(mangled)/memory"
        copyDir(src: memorySrc, dst: memoryDst, merge: true, report: &report)

        // 4. file-history/<sessionId>/
        let fhSrc = fromConfigDir + "/file-history/\(sessionId)"
        let fhDst = toConfigDir + "/file-history/\(sessionId)"
        copyDir(src: fhSrc, dst: fhDst, merge: false, report: &report)

        // 5. tasks/<sessionId>/
        let tasksSrc = fromConfigDir + "/tasks/\(sessionId)"
        let tasksDst = toConfigDir + "/tasks/\(sessionId)"
        copyDir(src: tasksSrc, dst: tasksDst, merge: false, report: &report)

        // 6. session-env/<sessionId>/
        let envSrc = fromConfigDir + "/session-env/\(sessionId)"
        let envDst = toConfigDir + "/session-env/\(sessionId)"
        copyDir(src: envSrc, dst: envDst, merge: false, report: &report)

        // 7. grove/usage/<sessionId>.json
        let usageSrc = fromConfigDir + "/grove/usage/\(sessionId).json"
        let usageDst = toConfigDir + "/grove/usage/\(sessionId).json"
        if fm.fileExists(atPath: usageSrc) {
            copySingleFile(src: usageSrc, dst: usageDst, report: &report)
        }

        return report
    }

    // MARK: - copySessionData helpers

    /// Copy a single file from `src` to `dst`, creating parent dirs.
    /// Skips (records skipped) if `dst` already exists. Records copied on success.
    private static func copySingleFile(src: String, dst: String, report: inout MigrateReport) {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst) {
            report.skipped.append(dst)
            return
        }
        let parent = (dst as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try fm.copyItem(atPath: src, toPath: dst)
            report.copied.append(dst)
        } catch {
            report.issues.append("copy \(src) → \(dst): \(error.localizedDescription)")
        }
    }

    /// Copy `src` directory tree to `dst`.
    /// - `merge: false`: whole-dir copy via `FileManager.copyItem` (skipped if dst exists).
    /// - `merge: true`:  per-file walk — copies only files the target lacks (never overwrites).
    /// Silently skips absent source dirs. Records each copied/skipped path.
    private static func copyDir(src: String, dst: String, merge: Bool, report: inout MigrateReport) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src, isDirectory: &isDir), isDir.boolValue else { return }

        if !merge {
            // Whole-dir: skip if dst already exists (idempotent)
            if fm.fileExists(atPath: dst) {
                report.skipped.append(dst)
                return
            }
            let parent = (dst as NSString).deletingLastPathComponent
            do {
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                try fm.copyItem(atPath: src, toPath: dst)
                report.copied.append(dst)
            } catch {
                report.issues.append("copy dir \(src) → \(dst): \(error.localizedDescription)")
            }
        } else {
            // Merge: walk source files, copy only those absent in target
            guard let enumerator = fm.enumerator(atPath: src) else { return }
            for case let rel as String in enumerator {
                let srcFile = src + "/" + rel
                var srcIsDir: ObjCBool = false
                guard fm.fileExists(atPath: srcFile, isDirectory: &srcIsDir),
                      !srcIsDir.boolValue else { continue }
                let dstFile = dst + "/" + rel
                if fm.fileExists(atPath: dstFile) {
                    report.skipped.append(dstFile)
                } else {
                    let dstParent = (dstFile as NSString).deletingLastPathComponent
                    do {
                        try fm.createDirectory(atPath: dstParent, withIntermediateDirectories: true)
                        try fm.copyItem(atPath: srcFile, toPath: dstFile)
                        report.copied.append(dstFile)
                    } catch {
                        report.issues.append("merge-copy \(srcFile) → \(dstFile): \(error.localizedDescription)")
                    }
                }
            }
        }
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
