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

    // MARK: - 6. migrateProjectConfig (Phase B)

    /// Copies the `projects[cwd]` entry from the source `.claude.json` into the
    /// target `.claude.json`, non-destructively. Other projects and top-level keys
    /// in the target are untouched. Creates the target file if absent. Preserves /
    /// sets file mode 0600 on the target (matching Claude's own behaviour).
    ///
    /// The caller is responsible for resolving the correct path for each account:
    ///   default account (configDir == ~/.claude) → $HOME/.claude.json
    ///   other accounts                           → <configDir>/.claude.json
    public static func migrateProjectConfig(
        cwd: String,
        fromHomeJSON: String,
        toHomeJSON: String
    ) -> MigrateReport {
        var report = MigrateReport()
        let fm = FileManager.default

        // Read source
        guard let srcData = fm.contents(atPath: fromHomeJSON),
              let srcObj = (try? JSONSerialization.jsonObject(with: srcData)) as? [String: Any],
              let srcProjects = srcObj["projects"] as? [String: Any],
              let sourceEntry = srcProjects[cwd] as? [String: Any] else {
            report.issues.append("migrateProjectConfig: source cwd '\(cwd)' not found in \(fromHomeJSON)")
            return report
        }

        // Read or create target
        var targetObj: [String: Any]
        if let dstData = fm.contents(atPath: toHomeJSON),
           let parsed = (try? JSONSerialization.jsonObject(with: dstData)) as? [String: Any] {
            targetObj = parsed
        } else {
            targetObj = [:]
        }

        // Merge only our cwd entry
        let merged = mergeClaudeProjectEntry(targetHomeJSON: targetObj, sourceEntry: sourceEntry, cwd: cwd)

        // Write back
        do {
            let outData = try JSONSerialization.data(withJSONObject: merged, options: .prettyPrinted)
            let url = URL(fileURLWithPath: toHomeJSON)
            let parent = url.deletingLastPathComponent().path
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try outData.write(to: url, options: .atomic)
            // Enforce 0600
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: toHomeJSON)
            report.copied.append(toHomeJSON)
        } catch {
            report.issues.append("migrateProjectConfig: write \(toHomeJSON): \(error.localizedDescription)")
        }

        return report
    }

    // MARK: - 7. migrateSettings (Phase C)

    /// Merges a curated set of keys from `<fromConfigDir>/settings.json` into
    /// `<toConfigDir>/settings.json`, non-destructively. Creates the target file
    /// if absent. The target's own values win on scalar conflicts.
    ///
    /// Keys merged: enabledPlugins, model, statusLine, extraKnownMarketplaces,
    ///              effortLevel, skipDangerousModePermissionPrompt, theme.
    ///
    /// statusLine rule: if the source `statusLine.command` contains `fromConfigDir`
    /// (i.e. it references a per-account script path), that key is SKIPPED entirely
    /// rather than copied verbatim into the target, which would point the target at
    /// the wrong account's script. A follow-up note is added to `report.copied`.
    /// When `statusLine` has no such reference it is merged normally.
    public static func migrateSettings(
        fromConfigDir: String,
        toConfigDir: String
    ) -> MigrateReport {
        var report = MigrateReport()
        let fm = FileManager.default
        let srcPath = fromConfigDir + "/settings.json"
        let dstPath = toConfigDir  + "/settings.json"

        guard let srcData = fm.contents(atPath: srcPath),
              var sourceSettings = (try? JSONSerialization.jsonObject(with: srcData)) as? [String: Any] else {
            report.issues.append("migrateSettings: cannot read \(srcPath)")
            return report
        }

        // statusLine rule: skip if command references fromConfigDir
        if let sl = sourceSettings["statusLine"] as? [String: Any],
           let cmd = sl["command"] as? String,
           cmd.contains(fromConfigDir) {
            sourceSettings.removeValue(forKey: "statusLine")
            report.copied.append(
                "note: statusLine skipped — command '\(cmd)' references fromConfigDir '\(fromConfigDir)'; " +
                "copy manually after confirming the correct per-account script path"
            )
        }

        // Read or create target
        var targetSettings: [String: Any]
        if let dstData = fm.contents(atPath: dstPath),
           let parsed = (try? JSONSerialization.jsonObject(with: dstData)) as? [String: Any] {
            targetSettings = parsed
        } else {
            targetSettings = [:]
        }

        let keys = ["enabledPlugins", "model", "statusLine",
                    "extraKnownMarketplaces", "effortLevel",
                    "skipDangerousModePermissionPrompt", "theme"]
        let merged = mergeSettingsKeys(target: targetSettings, source: sourceSettings, keys: keys)

        do {
            let outData = try JSONSerialization.data(withJSONObject: merged, options: .prettyPrinted)
            let url = URL(fileURLWithPath: dstPath)
            try fm.createDirectory(atPath: toConfigDir, withIntermediateDirectories: true)
            try outData.write(to: url, options: .atomic)
            report.copied.append(dstPath)
        } catch {
            report.issues.append("migrateSettings: write \(dstPath): \(error.localizedDescription)")
        }

        return report
    }

    // MARK: - 8. migratePlugins (Phase D)

    /// Copies plugin trees from `<fromConfigDir>/plugins/` to `<toConfigDir>/plugins/`,
    /// deduplicating by `<mkt>/<plugin>/<ver>` — any version already present at the
    /// target is skipped entirely (idempotent, non-destructive). Merges
    /// `known_marketplaces.json` and `installed_plugins.json`. Repoints every
    /// `installPath` in the merged `installed_plugins.json` from `fromConfigDir` to
    /// `toConfigDir`. Creates `<to>/plugins/cache` and `<to>/plugins/marketplaces`
    /// as needed. Never deletes or overwrites existing target content.
    ///
    /// Nesting correctness: each `<mkt>/<plugin>/<ver>` leaf is copied by enumerating
    /// files directly rather than calling `FileManager.copyItem` on the version dir when
    /// the parent already exists — avoids the `cp -R srcdir dstdir` nesting trap.
    public static func migratePlugins(
        fromConfigDir: String,
        toConfigDir: String
    ) -> MigrateReport {
        var report = MigrateReport()
        let fm = FileManager.default
        let fromCache = fromConfigDir + "/plugins/cache"
        let toCache   = toConfigDir   + "/plugins/cache"
        let fromMkts  = fromConfigDir + "/plugins/marketplaces"
        let toMkts    = toConfigDir   + "/plugins/marketplaces"

        // Ensure target plugin dirs exist
        for dir in [toCache, toMkts] {
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } catch {
                report.issues.append("migratePlugins: createDirectory \(dir): \(error.localizedDescription)")
            }
        }

        // --- Cache: iterate <mkt>/<plugin>/<ver> triples -------------------------
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: fromCache, isDirectory: &isDir), isDir.boolValue {
            let mkts = (try? fm.contentsOfDirectory(atPath: fromCache)) ?? []
            for mkt in mkts {
                let fromMktPath = fromCache + "/" + mkt
                let toMktPath   = toCache   + "/" + mkt
                let plugins = (try? fm.contentsOfDirectory(atPath: fromMktPath)) ?? []
                for plugin in plugins {
                    let fromPluginPath = fromMktPath + "/" + plugin
                    let toPluginPath   = toMktPath   + "/" + plugin
                    let versions = (try? fm.contentsOfDirectory(atPath: fromPluginPath)) ?? []
                    for ver in versions {
                        let fromVerPath = fromPluginPath + "/" + ver
                        let toVerPath   = toPluginPath   + "/" + ver

                        // Dedup: skip if target already has this version
                        if fm.fileExists(atPath: toVerPath) {
                            report.skipped.append(toVerPath)
                            continue
                        }

                        // Copy per-file into the correct destination path (no nesting trap)
                        do {
                            try fm.createDirectory(atPath: toVerPath, withIntermediateDirectories: true)
                        } catch {
                            report.issues.append("migratePlugins: mkdir \(toVerPath): \(error.localizedDescription)")
                            continue
                        }

                        guard let enumerator = fm.enumerator(atPath: fromVerPath) else { continue }
                        for case let rel as String in enumerator {
                            let srcFile = fromVerPath + "/" + rel
                            var srcIsDir: ObjCBool = false
                            guard fm.fileExists(atPath: srcFile, isDirectory: &srcIsDir),
                                  !srcIsDir.boolValue else {
                                if srcIsDir.boolValue {
                                    let dstSubDir = toVerPath + "/" + rel
                                    try? fm.createDirectory(atPath: dstSubDir, withIntermediateDirectories: true)
                                }
                                continue
                            }
                            let dstFile = toVerPath + "/" + rel
                            let dstParent = (dstFile as NSString).deletingLastPathComponent
                            do {
                                try fm.createDirectory(atPath: dstParent, withIntermediateDirectories: true)
                                try fm.copyItem(atPath: srcFile, toPath: dstFile)
                                report.copied.append(dstFile)
                            } catch {
                                report.issues.append("migratePlugins: copy \(srcFile) → \(dstFile): \(error.localizedDescription)")
                            }
                        }
                    }
                }
            }
        }

        // --- Marketplaces: per-mkt dir merge -------------------------------------
        if fm.fileExists(atPath: fromMkts, isDirectory: &isDir), isDir.boolValue {
            let mkts = (try? fm.contentsOfDirectory(atPath: fromMkts)) ?? []
            for mkt in mkts {
                let srcMkt = fromMkts + "/" + mkt
                let dstMkt = toMkts   + "/" + mkt
                if !fm.fileExists(atPath: dstMkt) {
                    do {
                        try fm.copyItem(atPath: srcMkt, toPath: dstMkt)
                        report.copied.append(dstMkt)
                    } catch {
                        report.issues.append("migratePlugins: copy mkt dir \(srcMkt): \(error.localizedDescription)")
                    }
                } else {
                    report.skipped.append(dstMkt)
                }
            }
        }

        // --- known_marketplaces.json: deepMerge ----------------------------------
        let fromKnown = fromConfigDir + "/plugins/known_marketplaces.json"
        let toKnown   = toConfigDir   + "/plugins/known_marketplaces.json"
        if let srcData = fm.contents(atPath: fromKnown),
           let srcObj = (try? JSONSerialization.jsonObject(with: srcData)) as? [String: Any] {
            let targetObj: [String: Any]
            if let dstData = fm.contents(atPath: toKnown),
               let parsed = (try? JSONSerialization.jsonObject(with: dstData)) as? [String: Any] {
                targetObj = parsed
            } else {
                targetObj = [:]
            }
            let merged = deepMergeJSON(target: targetObj, source: srcObj)
            if let outData = try? JSONSerialization.data(withJSONObject: merged, options: .prettyPrinted) {
                do {
                    try outData.write(to: URL(fileURLWithPath: toKnown), options: .atomic)
                    report.copied.append(toKnown)
                } catch {
                    report.issues.append("migratePlugins: write \(toKnown): \(error.localizedDescription)")
                }
            }
        }

        // --- installed_plugins.json: repoint source FIRST, merge, then dedup ------
        let fromInstalled = fromConfigDir + "/plugins/installed_plugins.json"
        let toInstalled   = toConfigDir   + "/plugins/installed_plugins.json"
        if let srcData = fm.contents(atPath: fromInstalled),
           let srcObj = (try? JSONSerialization.jsonObject(with: srcData)) as? [String: Any] {
            let targetObj: [String: Any]
            if let dstData = fm.contents(atPath: toInstalled),
               let parsed = (try? JSONSerialization.jsonObject(with: dstData)) as? [String: Any] {
                targetObj = parsed
            } else {
                targetObj = [:]
            }
            // Step 1: repoint source installPaths into target-space BEFORE merging,
            //         so fingerprints are comparable to target records.
            let repointedSrc = repointPluginInstallPaths(
                installedPlugins: srcObj,
                fromConfigDir: fromConfigDir,
                toConfigDir: toConfigDir
            )
            // Step 2: deep-merge (target wins on scalar conflicts; arrays unioned).
            let mergedRaw = deepMergeJSON(target: targetObj, source: repointedSrc)
            // Step 3: dedup each plugins[key] array by (version, installPath) —
            //         both now in target-space — keeping first (target-native) occurrence.
            let merged = dedupPluginRecords(mergedRaw)
            do {
                let outData = try JSONSerialization.data(withJSONObject: merged, options: .prettyPrinted)
                try outData.write(to: URL(fileURLWithPath: toInstalled), options: .atomic)
                report.copied.append(toInstalled)
            } catch {
                report.issues.append("migratePlugins: write \(toInstalled): \(error.localizedDescription)")
            }
        }

        return report
    }

    // MARK: - 9. migrateSession orchestrator

    /// Full cross-account session migration orchestrator. Runs all four phases:
    ///   A: copySessionData   — transcript, aux, memory, file-history, tasks, session-env, usage
    ///   B: migrateProjectConfig — .claude.json projects[cwd] merge
    ///   C: migrateSettings   — settings.json curated-key merge
    ///   D: migratePlugins    — plugin tree copy + installPath repoint
    ///
    /// Returns a merged MigrateReport. Idempotent and non-destructive.
    public static func migrateSession(
        sessionId: String,
        cwd: String,
        fromConfigDir: String,
        toConfigDir: String,
        fromHomeJSON: String,
        toHomeJSON: String,
        mirrorRoot: String?,
        fromAccountKey: String
    ) -> MigrateReport {
        var report = MigrateReport()

        func merge(_ r: MigrateReport) {
            report.copied  += r.copied
            report.skipped += r.skipped
            report.issues  += r.issues
        }

        merge(copySessionData(
            sessionId: sessionId, cwd: cwd,
            fromConfigDir: fromConfigDir, toConfigDir: toConfigDir,
            mirrorRoot: mirrorRoot, fromAccountKey: fromAccountKey
        ))
        merge(migrateProjectConfig(
            cwd: cwd,
            fromHomeJSON: fromHomeJSON,
            toHomeJSON: toHomeJSON
        ))
        merge(migrateSettings(fromConfigDir: fromConfigDir, toConfigDir: toConfigDir))
        merge(migratePlugins(fromConfigDir: fromConfigDir, toConfigDir: toConfigDir))

        return report
    }

    // MARK: - Plugin dedup helper

    /// Deduplicates each `plugins[key]` array in `installedPlugins` by `(version, installPath)`.
    /// First occurrence wins (preserves target-native records). Other top-level keys untouched.
    /// Assumes installPaths are already in the same (target) space — call
    /// `repointPluginInstallPaths` on the source before merging.
    private static func dedupPluginRecords(_ installedPlugins: [String: Any]) -> [String: Any] {
        var result = installedPlugins
        guard var plugins = result["plugins"] as? [String: Any] else { return result }
        for (key, val) in plugins {
            guard let entries = val as? [[String: Any]] else { continue }
            var seen = Set<String>()
            var deduped: [[String: Any]] = []
            for entry in entries {
                let v = (entry["version"] as? String) ?? ""
                let p = (entry["installPath"] as? String) ?? ""
                let fingerprint = "\(v)\u{0}\(p)"
                if !seen.contains(fingerprint) {
                    seen.insert(fingerprint)
                    deduped.append(entry)
                }
            }
            plugins[key] = deduped
        }
        result["plugins"] = plugins
        return result
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
