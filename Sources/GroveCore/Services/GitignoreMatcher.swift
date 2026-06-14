import Foundation

// A pure, dependency-free `.gitignore` matcher (spec STAGE 2). NO regex engine and
// NO shelling to `git check-ignore`: we parse each pattern line into segments and
// match with a small recursive glob. Mirrors the namespacing style of
// CodeStatsEngine / RateLimitModel: value types + one stateless evaluator.
//
// The same parser handles `.ignorestats` files (a sibling ignore list this tool
// uses to drop paths from code stats) — it is byte-for-byte the gitignore syntax.

// MARK: - Segment matcher

/// One path-segment matcher: a sequence of tokens applied to a single path
/// component (no `/` inside). `**` is special — it is NOT a segment matcher; it is
/// handled one level up in `matchSegments` because it spans whole components.
struct GitignoreSegment: Equatable {
    /// Tokens within a single component, matched left→right against the component.
    enum Token: Equatable {
        case literal(String)   // exact run of non-glob characters
        case star              // `*`  -> zero+ chars, never `/`
        case question          // `?`  -> exactly one char, never `/`
    }
    let tokens: [Token]

    /// True if this whole segment matches `component` (a single path component).
    func matches(_ component: Substring) -> Bool {
        Self.matchTokens(tokens[...], component)
    }

    /// Recursive token matcher against one component. `*`/`?` never cross `/`, but a
    /// component already has no `/`, so they just consume characters within it.
    private static func matchTokens(_ tokens: ArraySlice<Token>, _ s: Substring) -> Bool {
        guard let first = tokens.first else { return s.isEmpty }
        let rest = tokens.dropFirst()
        switch first {
        case .literal(let lit):
            guard s.hasPrefix(lit) else { return false }
            return matchTokens(rest, s.dropFirst(lit.count))
        case .question:
            guard let _ = s.first else { return false }
            return matchTokens(rest, s.dropFirst())
        case .star:
            // `*` matches zero+ chars: try every split point (greedy isn't required
            // for correctness, so we just search).
            var idx = s.startIndex
            while true {
                if matchTokens(rest, s[idx...]) { return true }
                if idx == s.endIndex { return false }
                idx = s.index(after: idx)
            }
        }
    }
}

// MARK: - Pattern

/// One parsed `.gitignore` line. `negated` re-includes; `directoryOnly` (trailing
/// `/`) matches directories only; `anchored` pins the first segment to the base of
/// the scope (set when the pattern has a leading `/` OR any non-trailing internal
/// `/`). A non-anchored pattern matches at ANY depth (its leading segment may align
/// with any component). A leading `**/` and a trailing `/**` desugar into a `nil`
/// element of `segments` meaning "match zero+ components here".
public struct GitignorePattern: Equatable {
    public let negated: Bool
    public let directoryOnly: Bool
    public let anchored: Bool
    /// Component matchers; a `nil` entry is a `**` (zero+ components) placeholder.
    let segments: [GitignoreSegment?]

    /// Parse one raw line. Returns nil for blank / comment lines (which contribute
    /// no rule). Implements the gitignore lexing rules from the spec.
    public static func parse(_ rawLine: String) -> GitignorePattern? {
        // 1. A line that is blank or starts with `#` is skipped. `\#` escapes a
        //    literal leading `#` (and `\!` a literal leading `!`, handled below).
        var line = Substring(rawLine)

        // Strip trailing whitespace UNLESS the last space is backslash-escaped.
        line = stripTrailingWhitespace(line)
        if line.isEmpty { return nil }
        if line.first == "#" { return nil }   // comment (unescaped #)

        // 2. Leading `!` negates. `\#` / `\!` un-escape a literal first char.
        var negated = false
        if line.first == "!" {
            negated = true
            line = line.dropFirst()
        } else if line.hasPrefix("\\#") || line.hasPrefix("\\!") {
            line = line.dropFirst()           // drop the backslash; keep the literal
        }
        if line.isEmpty { return nil }

        // 3. Trailing `/` -> directory-only (and is removed before segmenting).
        var directoryOnly = false
        if line.hasSuffix("/") {
            directoryOnly = true
            line = line.dropLast()
        }
        if line.isEmpty { return nil }

        // 4. Anchoring. A leading `/` anchors to the scope root (and is consumed).
        //    Otherwise, ANY remaining internal `/` (we've already dropped a trailing
        //    one) also anchors — gitignore treats `a/b` as rooted, while a bare
        //    `name` floats to any depth.
        var anchored = false
        if line.first == "/" {
            anchored = true
            line = line.dropFirst()
        } else if line.contains("/") {
            anchored = true
        }
        if line.isEmpty { return nil }

        // 5. Split into `/`-separated components and desugar `**`.
        let rawComponents = line.split(separator: "/", omittingEmptySubsequences: false)
        var segments: [GitignoreSegment?] = []
        for comp in rawComponents {
            if comp == "**" {
                segments.append(nil)          // zero+ components
            } else {
                segments.append(GitignorePattern.tokenize(comp))
            }
        }
        // An empty component (`a//b`) yields an empty-token segment that only matches
        // an empty component; gitignore never produces empty path components, so such
        // a pattern simply never matches — acceptable and matches git's behavior.

        return GitignorePattern(negated: negated, directoryOnly: directoryOnly,
                                anchored: anchored, segments: segments)
    }

    /// Tokenize ONE component into literal / `*` / `?` tokens. Backslash escapes the
    /// next char into a literal (so `\*` is a literal asterisk). Consecutive literal
    /// chars are coalesced into one `.literal` run.
    static func tokenize(_ comp: Substring) -> GitignoreSegment {
        var tokens: [GitignoreSegment.Token] = []
        var literal = ""
        func flush() {
            if !literal.isEmpty { tokens.append(.literal(literal)); literal = "" }
        }
        var idx = comp.startIndex
        while idx < comp.endIndex {
            let ch = comp[idx]
            switch ch {
            case "\\":
                // Escape: next char is literal (if any).
                let next = comp.index(after: idx)
                if next < comp.endIndex { literal.append(comp[next]); idx = next }
            case "*":
                flush(); tokens.append(.star)
            case "?":
                flush(); tokens.append(.question)
            default:
                literal.append(ch)
            }
            idx = comp.index(after: idx)
        }
        flush()
        return GitignoreSegment(tokens: tokens)
    }

    // MARK: trailing-whitespace handling

    /// Strip trailing spaces/tabs, but keep a trailing space that is escaped by a
    /// preceding backslash (e.g. `foo\ ` keeps one literal space). The backslash that
    /// escapes the kept space is removed so tokenizing sees a plain literal.
    private static func stripTrailingWhitespace(_ s: Substring) -> Substring {
        // Find the cut point: last index whose char is non-whitespace OR is a space
        // protected by a `\`. Simplest correct approach: walk from the end, counting
        // trailing whitespace, then look at the char before the run.
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            let c = s[prev]
            if c == " " || c == "\t" { end = prev } else { break }
        }
        // `end` is now the start of the trailing whitespace run (or endIndex if none).
        if end == s.endIndex { return s }
        // If the char immediately before the whitespace run is a backslash, the FIRST
        // whitespace char is escaped: keep it (and drop the backslash) — drop the rest.
        let beforeRun = s.index(before: end)
        if s[beforeRun] == "\\" {
            // Rebuild: content up to (and excluding) the backslash, + one space.
            let kept = s[s.startIndex..<beforeRun] + " "
            return Substring(kept)
        }
        return s[s.startIndex..<end]
    }

    // MARK: Matching

    /// True if this pattern matches `components` (the relative path split on `/`).
    /// `isDirectory` gates `directoryOnly`. Negation is NOT considered here — the
    /// caller (`GitignoreRules`) applies last-match-wins with the `negated` flag.
    ///
    /// A path is matched when the pattern matches the FULL path OR any ANCESTOR
    /// directory prefix of it: in git, ignoring directory `build/` ignores every
    /// descendant, and a bare `build` ignores any `build` directory's contents too.
    /// We therefore test each prefix `components[0..<k]` (k from full length down to
    /// 1); a non-final prefix is always a directory, so `directoryOnly` is satisfied
    /// for those, while the full path uses the caller's `isDirectory`.
    func matches(components: [Substring], isDirectory: Bool) -> Bool {
        var k = components.count
        while k >= 1 {
            let prefix = Array(components[0..<k])
            let prefixIsDir = (k < components.count) || isDirectory
            if matchesExact(components: prefix, isDirectory: prefixIsDir) { return true }
            k -= 1
        }
        return false
    }

    /// Match the pattern against EXACTLY `components` (no ancestor expansion).
    private func matchesExact(components: [Substring], isDirectory: Bool) -> Bool {
        if directoryOnly && !isDirectory { return false }
        if anchored {
            // Anchored: the segment list must align starting at component 0.
            return GitignorePattern.matchSegments(segments[...], components[...])
        }
        // Floating (basename) pattern: it may begin at ANY depth. Equivalent to a
        // leading `**`, so try matching the segments against every suffix.
        var start = 0
        while start <= components.count {
            if GitignorePattern.matchSegments(segments[...], components[start...]) { return true }
            start += 1
        }
        return false
    }

    /// Core recursive segment matcher. A `nil` segment is `**`: zero+ components in
    /// leading/middle position, but ONE+ components when it is the TRAILING segment
    /// (`abc/**` = "everything strictly inside abc"). Plain segments consume exactly
    /// one component. When segments run out the path must be fully consumed; ancestor-
    /// directory containment (an ignored dir ignoring its descendants) is handled one
    /// level up in `matches(components:)` by testing each path prefix.
    static func matchSegments(_ segs: ArraySlice<GitignoreSegment?>,
                              _ comps: ArraySlice<Substring>) -> Bool {
        guard let first = segs.first else {
            // No more segments: match iff no components remain.
            return comps.isEmpty
        }
        let restSegs = segs.dropFirst()

        guard let seg = first else {
            // `**` placeholder.
            if restSegs.isEmpty {
                // TRAILING `/**` means "everything strictly inside" -> it must consume
                // at LEAST one component (so `abc/**` matches `abc/x` but not `abc`).
                return !comps.isEmpty
            }
            // Leading/middle `**`: consume zero+ components, then match the rest at each
            // point. Try zero first, then one more component each step.
            var c = comps
            while true {
                if matchSegments(restSegs, c) { return true }
                if c.isEmpty { return false }
                c = c.dropFirst()
            }
        }

        // A concrete segment must match the FIRST remaining component.
        guard let head = comps.first, seg.matches(head) else { return false }
        return matchSegments(restSegs, comps.dropFirst())
    }
}

// MARK: - Rules (one file's worth of patterns)

/// An ordered list of patterns from a single ignore file. `match` applies
/// last-match-wins: the final pattern whose glob matches decides, so a later
/// negation (`!keep`) re-includes a path an earlier pattern excluded.
public struct GitignoreRules: Equatable {
    public let patterns: [GitignorePattern]

    public init(patterns: [GitignorePattern]) {
        self.patterns = patterns
    }

    /// Parse a whole ignore-file's `contents` (newline-separated) into rules, in
    /// order. Blank/comment lines drop out. Handles `.gitignore` and `.ignorestats`
    /// identically (same syntax).
    public init(contents: String) {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        var out: [GitignorePattern] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let p = GitignorePattern.parse(String(line)) { out.append(p) }
        }
        self.patterns = out
    }

    /// Decision for one path under THIS file's rules: `.ignored` / `.included`
    /// (an explicit `!` re-include) / `.unmatched` (no pattern touched it). The
    /// scope distinguishes an explicit re-include from "never matched" so a parent
    /// scope's earlier ignore can still win or lose correctly.
    public enum Decision: Equatable { case ignored, included, unmatched }

    /// Evaluate `relativePath` (relative to THIS file's directory) against the
    /// ordered patterns, last-match-wins.
    public func decide(relativePath: String, isDirectory: Bool) -> Decision {
        let components = GitignoreRules.split(relativePath)
        guard !components.isEmpty else { return .unmatched }
        var decision: Decision = .unmatched
        for pattern in patterns where pattern.matches(components: components, isDirectory: isDirectory) {
            decision = pattern.negated ? .included : .ignored
        }
        return decision
    }

    /// Convenience boolean for callers that only have one ignore file: true iff the
    /// last matching pattern ignores the path.
    public func match(relativePath: String, isDirectory: Bool) -> Bool {
        decide(relativePath: relativePath, isDirectory: isDirectory) == .ignored
    }

    /// Split a relative path into non-empty components (drops `.` and empties).
    static func split(_ path: String) -> [Substring] {
        Substring(path).split(separator: "/").filter { $0 != "." }
    }
}

// MARK: - Scope stack (per-directory rules during a walk)

/// A stack of `(directoryPath, rules)` frames, deepest LAST. During a directory
/// walk you `push` a frame when entering a directory that has a `.gitignore`
/// (recording its absolute/relative dir) and `pop` it on the way out. Matching a
/// candidate path evaluates DEEPEST-FIRST then up: the first scope that reaches a
/// non-`unmatched` decision wins (a deeper file's `!keep` overrides a shallower
/// ignore), exactly like git's precedence.
public struct GitignoreScope: Equatable {
    /// One frame: the directory (relative to the walk root, "" for the root) whose
    /// ignore file produced `rules`.
    public struct Frame: Equatable {
        public let directory: String   // e.g. "" , "src", "src/gen"
        public let rules: GitignoreRules
        public init(directory: String, rules: GitignoreRules) {
            self.directory = directory
            self.rules = rules
        }
    }

    public private(set) var frames: [Frame]

    public init(frames: [Frame] = []) { self.frames = frames }

    public mutating func push(_ frame: Frame) { frames.append(frame) }

    @discardableResult
    public mutating func pop() -> Frame? { frames.popLast() }

    /// Should `path` (relative to the WALK ROOT) be ignored? Evaluated deepest-first:
    /// the rules of the nearest enclosing directory get the first say; if they don't
    /// touch the path (`.unmatched`), we fall back to the parent scope, and so on.
    /// Each frame sees the path made relative to ITS directory.
    public func isIgnored(path: String, isDirectory: Bool) -> Bool {
        for frame in frames.reversed() {
            guard let relative = GitignoreScope.relativize(path: path, under: frame.directory)
            else { continue }   // path isn't inside this frame's directory -> skip
            switch frame.rules.decide(relativePath: relative, isDirectory: isDirectory) {
            case .ignored:  return true
            case .included: return false
            case .unmatched: continue
            }
        }
        return false
    }

    /// Make `path` (root-relative) relative to `directory` (also root-relative).
    /// Returns nil when `path` is not under `directory`. "" directory == root, so
    /// every path is under it unchanged.
    static func relativize(path: String, under directory: String) -> String? {
        if directory.isEmpty { return path }
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
