import Foundation

/// A previously-stat'd-and-classified file, keyed by absolute path in the caller's
/// cache. We re-use the classification when a file's (mtime, size) are unchanged
/// since the last scan, so the steady-state 15s loop only re-reads files that
/// actually changed. `language` is the display name (nil for a recognized-but-…
/// — actually always non-nil here, since unknown extensions never enter the cache).
public struct CachedFile: Sendable, Equatable {
    public let mtime: Date
    public let size: Int
    public let classification: FileClassification
    public let language: String
    public init(mtime: Date, size: Int, classification: FileClassification, language: String) {
        self.mtime = mtime
        self.size = size
        self.classification = classification
        self.language = language
    }
}

/// Walks a project directory and tallies source lines per language, honoring
/// `.gitignore` / `.ignorestats` scopes and a caller-supplied set of extra ignored
/// folders. Pure aside from filesystem reads: it takes the wall-clock `now` so the
/// produced `CodeStats.scannedAt` is deterministic in tests. The walk mirrors
/// `GitService.discoverRepos` (iterative queue, `.isSymbolicLinkKey` skip, the same
/// `alwaysSkippedDirNames`) so the two stay consistent.
public struct CodeStatsScanner: Sendable {

    /// Files larger than this are skipped entirely (never read or classified): a
    /// generated/minified blob would dominate the tally and is rarely "source".
    static let maxFileBytes = 5 * 1024 * 1024

    public init() {}

    /// Scan `projectPath`, reusing `cache` for unchanged files (and updating it in
    /// place so the next tick is cheap). `extraIgnoredFolders` holds project-root-
    /// relative directory paths (e.g. "vendor", "src/generated") to skip wholesale,
    /// on top of `.gitignore`/`.ignorestats` and `GitService.alwaysSkippedDirNames`.
    public func scan(projectPath: String,
                     extraIgnoredFolders: Set<String>,
                     now: Date = Date(),
                     cache: inout [String: CachedFile]) -> CodeStats {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: expandTilde(projectPath)).standardizedFileURL

        // Per-language running tallies, plus the whole-scan totals.
        var perLang: [String: (files: Int, code: Int, comment: Int, blank: Int)] = [:]
        var totalFiles = 0, totalCode = 0, totalComment = 0, totalBlank = 0
        var skippedBinary = 0

        // Cache entries we actually touched this scan; everything else (deleted /
        // newly-ignored files) is dropped so the cache can't grow without bound.
        var nextCache: [String: CachedFile] = [:]

        // BFS queue of (directory, root-relative path, scope-stack depth at entry).
        // The scope stack carries the .gitignore/.ignorestats frames in force for a
        // directory; we record how deep it was when we ENTERED each dir so we can
        // pop frames back off as the BFS moves to a sibling subtree.
        var scope = GitignoreScope()
        struct Frame { let url: URL; let relative: String; let scopeDepthAtEntry: Int }
        var queue: [Frame] = [Frame(url: root, relative: "", scopeDepthAtEntry: 0)]
        var nextIndex = 0

        while nextIndex < queue.count {
            let frame = queue[nextIndex]
            nextIndex += 1

            // BFS jumps between subtrees, so reset the scope stack to the frame count
            // this directory was discovered with, then push this directory's own
            // ignore files. (A pure-DFS walk could push/pop linearly; BFS can't.)
            while scope.frames.count > frame.scopeDepthAtEntry { scope.pop() }
            for newFrame in ignoreFrames(in: frame.url, relative: frame.relative, fm: fm) {
                scope.push(newFrame)
            }
            let scopeDepthHere = scope.frames.count

            let names = (try? fm.contentsOfDirectory(atPath: frame.url.path)) ?? []
            for name in names.sorted() {
                let child = frame.url.appendingPathComponent(name)
                let childRelative = frame.relative.isEmpty ? name : frame.relative + "/" + name

                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: child.path, isDirectory: &isDirectory) else { continue }

                if isDirectory.boolValue {
                    // Never descend symlinked directories (cycle / escape risk).
                    if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                    // The always-skipped infrastructure dirs (.git, node_modules, …).
                    if GitService.alwaysSkippedDirNames.contains(name) { continue }
                    // Caller's extra ignored folders, matched by root-relative path.
                    if extraIgnoredFolders.contains(childRelative) { continue }
                    // .gitignore / .ignorestats directory ignores.
                    if scope.isIgnored(path: childRelative, isDirectory: true) { continue }
                    queue.append(Frame(url: child, relative: childRelative, scopeDepthAtEntry: scopeDepthHere))
                    continue
                }

                // A regular file: skip if any ignore scope drops it.
                if scope.isIgnored(path: childRelative, isDirectory: false) { continue }
                // Recognize the language by extension; unknown extensions never count.
                guard let lang = CodeStatsEngine.language(forPath: name) else { continue }

                guard let classified = classify(file: child, language: lang, name: childRelative,
                                                cache: &cache, nextCache: &nextCache,
                                                skippedBinary: &skippedBinary, fm: fm)
                else { continue }

                var agg = perLang[lang.name] ?? (0, 0, 0, 0)
                agg.files += 1
                agg.code += classified.code
                agg.comment += classified.comment
                agg.blank += classified.blank
                perLang[lang.name] = agg

                totalFiles += 1
                totalCode += classified.code
                totalComment += classified.comment
                totalBlank += classified.blank
            }
        }

        cache = nextCache

        // Sort DESC by code (most code first), matching CodeStats.byLanguage's contract.
        let byLanguage = perLang
            .map { LanguageStats(language: $0.key, files: $0.value.files,
                                 code: $0.value.code, comment: $0.value.comment,
                                 blank: $0.value.blank,
                                 total: $0.value.code + $0.value.comment + $0.value.blank) }
            .sorted { ($0.code, $0.language) > ($1.code, $1.language) }

        return CodeStats(
            totalFiles: totalFiles,
            totalLines: totalCode + totalComment + totalBlank,
            code: totalCode, comment: totalComment, blank: totalBlank,
            byLanguage: byLanguage, scannedAt: now, skippedBinary: skippedBinary)
    }

    // MARK: - Directory skeleton (for the exclusion tree)

    /// Emit the project's directory skeleton as a `DirNode` tree — the ONLY I/O the
    /// stats-exclusion UI needs (no file reads, no classification). It applies the
    /// same always-skipped-dir + symlink guards as `scan`, but DELIBERATELY does NOT
    /// apply `.gitignore`/`.ignorestats` or `extraIgnoredFolders`: the picker must
    /// still show folders so a previously-excluded one can be re-included, and the
    /// caller marks excluded rows from config. Children are sorted by name; the root
    /// node's `relativePath` is "". `maxDepth` bounds the walk (the picker is shallow).
    public func directoryTree(projectPath: String, maxDepth: Int = 4) -> DirNode {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: expandTilde(projectPath)).standardizedFileURL
        return node(url: root, name: root.lastPathComponent, relative: "",
                    depth: 0, maxDepth: maxDepth, fm: fm)
    }

    /// Recursively build one `DirNode`. Pure aside from `contentsOfDirectory`/stat —
    /// it never opens or reads a file.
    private func node(url: URL, name: String, relative: String,
                      depth: Int, maxDepth: Int, fm: FileManager) -> DirNode {
        guard depth < maxDepth else { return DirNode(name: name, relativePath: relative, children: []) }
        let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        var children: [DirNode] = []
        for childName in names.sorted() {
            let child = url.appendingPathComponent(childName)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            // Same guards as scan(): never descend symlinks or infrastructure dirs.
            if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            if GitService.alwaysSkippedDirNames.contains(childName) { continue }
            let childRelative = relative.isEmpty ? childName : relative + "/" + childName
            children.append(node(url: child, name: childName, relative: childRelative,
                                 depth: depth + 1, maxDepth: maxDepth, fm: fm))
        }
        return DirNode(name: name, relativePath: relative, children: children)
    }

    // MARK: - Per-file classification (with mtime/size cache)

    /// Classify one file, re-using `cache` when its (mtime, size) are unchanged.
    /// Returns nil when the file should not be counted at all (too large, binary, or
    /// unreadable) — binary/too-large files do not enter `nextCache` so a later edit
    /// re-evaluates them. On a cache hit or a fresh read, the result is recorded in
    /// `nextCache`.
    private func classify(file url: URL, language lang: LanguageDefinition, name relative: String,
                          cache: inout [String: CachedFile], nextCache: inout [String: CachedFile],
                          skippedBinary: inout Int, fm: FileManager) -> FileClassification? {
        let key = url.path
        // Stat before read: cheap and lets us short-circuit unchanged files.
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue else { return nil }

        if size > Self.maxFileBytes { return nil }

        if let hit = cache[key], hit.mtime == mtime, hit.size == size, hit.language == lang.name {
            nextCache[key] = hit
            return hit.classification
        }

        guard let data = try? Data(contentsOf: url) else { return nil }
        if CodeStatsEngine.isLikelyBinary(data) { skippedBinary += 1; return nil }
        let contents = String(decoding: data, as: UTF8.self)
        let classification = CodeStatsEngine.classify(contents: contents, language: lang)
        nextCache[key] = CachedFile(mtime: mtime, size: size,
                                    classification: classification, language: lang.name)
        return classification
    }

    // MARK: - Ignore-file scope frames

    /// Load this directory's `.gitignore` then `.ignorestats` (in that order, so a
    /// later `.ignorestats` rule wins within the directory) into scope frames keyed
    /// by the directory's root-relative path. Empty/absent files contribute nothing.
    private func ignoreFrames(in dir: URL, relative: String, fm: FileManager) -> [GitignoreScope.Frame] {
        var frames: [GitignoreScope.Frame] = []
        for fileName in [".gitignore", ".ignorestats"] {
            let path = dir.appendingPathComponent(fileName)
            guard let contents = try? String(contentsOf: path, encoding: .utf8) else { continue }
            let rules = GitignoreRules(contents: contents)
            guard !rules.patterns.isEmpty else { continue }
            frames.append(GitignoreScope.Frame(directory: relative, rules: rules))
        }
        return frames
    }
}
