import Foundation

// MARK: - Result value types

/// Per-language line tally. `total` = code + comment + blank for the language.
public struct LanguageStats: Sendable, Equatable, Codable {
    public let language: String
    public let files: Int
    public let code: Int
    public let comment: Int
    public let blank: Int
    public let total: Int
    public init(language: String, files: Int, code: Int, comment: Int, blank: Int, total: Int) {
        self.language = language
        self.files = files
        self.code = code
        self.comment = comment
        self.blank = blank
        self.total = total
    }
}

/// Whole-scan tally. `byLanguage` is sorted DESC by `code` (most code first).
/// `skippedBinary` counts files the caller dropped via `isLikelyBinary`.
public struct CodeStats: Sendable, Equatable, Codable {
    public let totalFiles: Int
    public let totalLines: Int
    public let code: Int
    public let comment: Int
    public let blank: Int
    public let byLanguage: [LanguageStats]
    public let scannedAt: Date
    public let skippedBinary: Int
    public init(totalFiles: Int, totalLines: Int, code: Int, comment: Int, blank: Int,
                byLanguage: [LanguageStats], scannedAt: Date, skippedBinary: Int) {
        self.totalFiles = totalFiles
        self.totalLines = totalLines
        self.code = code
        self.comment = comment
        self.blank = blank
        self.byLanguage = byLanguage
        self.scannedAt = scannedAt
        self.skippedBinary = skippedBinary
    }
}

/// A lightweight directory-tree skeleton: a folder's project-root-relative path,
/// its leaf `name`, and its child directories (files are NOT modelled — only the
/// folder structure the stats-exclusion tree needs). Emitted by
/// `CodeStatsScanner.directoryTree` (the only I/O step). `relativePath` is "" for
/// the root.
public struct DirNode: Sendable, Equatable {
    public let name: String
    public let relativePath: String
    public let children: [DirNode]
    public init(name: String, relativePath: String, children: [DirNode]) {
        self.name = name
        self.relativePath = relativePath
        self.children = children
    }
}

/// One file's classified line counts (code / comment / blank). Sums to line count.
public struct FileClassification: Sendable, Equatable {
    public let code: Int
    public let comment: Int
    public let blank: Int
    public init(code: Int, comment: Int, blank: Int) {
        self.code = code
        self.comment = comment
        self.blank = blank
    }
}

// MARK: - Language model

/// Comment delimiters for a language. `lineComment` tokens start a comment that
/// runs to end of line; `blockComment` pairs open/close a (possibly multi-line)
/// block. Empty arrays mean "this language has no comments of that kind".
public struct CommentSyntax: Sendable, Equatable {
    public let lineComment: [String]
    public let blockComment: [(open: String, close: String)]
    /// When true, a block open/close delimiter only counts at COLUMN 0 (no leading
    /// whitespace) — Ruby's `=begin`/`=end` rule. C-style `/* */` blocks float
    /// anywhere on the line, so this is false for every language but Ruby. Without
    /// it an indented `=begin` (not valid Ruby comment syntax) is miscounted as a
    /// comment instead of code.
    public let blockRequiresLineStart: Bool
    public init(lineComment: [String], blockComment: [(open: String, close: String)],
                blockRequiresLineStart: Bool = false) {
        self.lineComment = lineComment
        self.blockComment = blockComment
        self.blockRequiresLineStart = blockRequiresLineStart
    }

    // Tuples aren't auto-Equatable, so compare blocks element-wise.
    public static func == (lhs: CommentSyntax, rhs: CommentSyntax) -> Bool {
        lhs.lineComment == rhs.lineComment
            && lhs.blockRequiresLineStart == rhs.blockRequiresLineStart
            && lhs.blockComment.count == rhs.blockComment.count
            && zip(lhs.blockComment, rhs.blockComment).allSatisfy { $0.open == $1.open && $0.close == $1.close }
    }
}

/// A language: display `name`, the file `extensions` (lowercased, no dot) that
/// map to it, and its `comment` syntax.
public struct LanguageDefinition: Sendable, Equatable {
    public let name: String
    public let extensions: [String]
    public let comment: CommentSyntax
    public init(name: String, extensions: [String], comment: CommentSyntax) {
        self.name = name
        self.extensions = extensions
        self.comment = comment
    }
}

// MARK: - Stats engine

/// Pure, dependency-free source-line classifier and language table. Does NO file
/// I/O — callers feed it `contents:` strings (and use `isLikelyBinary` to drop
/// binaries first). Mirrors the namespacing style of ModelPricing / RateLimitModel:
/// one `public enum`, one maintainable table. Named `CodeStatsEngine` so it never
/// collides with the `CodeStats` result struct above.
public enum CodeStatsEngine {

    // MARK: Language table

    /// The ONE place to add/maintain languages. Convenience builder keeps each row
    /// terse: line tokens + block (open,close) pairs. Markdown/json carry no
    /// comment tokens (json is treated as all-code; markdown too).
    private static func lang(_ name: String, _ exts: [String],
                             line: [String] = [], block: [(String, String)] = [],
                             blockAtLineStart: Bool = false) -> LanguageDefinition {
        LanguageDefinition(name: name, extensions: exts,
                           comment: CommentSyntax(lineComment: line,
                                                  blockComment: block.map { (open: $0.0, close: $0.1) },
                                                  blockRequiresLineStart: blockAtLineStart))
    }

    // MARK: Data/Prose classification

    /// Languages classified as "Data/Prose" rather than "Code": structured-data and
    /// markup formats whose line counts shouldn't inflate a headline "Code" number.
    /// The names match `LanguageDefinition.name` strings in `languageTable` exactly.
    public static let dataProseLanguages: Set<String> = ["Markdown", "JSON", "YAML", "TOML"]

    /// True when `languageName` is a Data/Prose language (Markdown/JSON/YAML/TOML).
    /// Robust to unknown/empty names (returns false).
    public static func isDataProse(_ languageName: String) -> Bool {
        dataProseLanguages.contains(languageName)
    }

    /// Shipped languages (spec): extension → line/block comment syntax.
    public static let languageTable: [LanguageDefinition] = [
        lang("Swift",      ["swift"],                                   line: ["//"], block: [("/*", "*/")]),
        lang("TypeScript/JavaScript", ["ts", "tsx", "js", "jsx", "mjs", "cjs"],
                                                                        line: ["//"], block: [("/*", "*/")]),
        // Python: triple-quoted strings are treated as block comments. See the
        // heuristic-limitation note on `classify` — this miscounts triple-quoted
        // STRING LITERALS used as values, which is the accepted trade-off.
        lang("Python",     ["py", "pyi"],                               line: ["#"],  block: [("\"\"\"", "\"\"\""), ("'''", "'''")]),
        lang("Go",         ["go"],                                      line: ["//"], block: [("/*", "*/")]),
        lang("Rust",       ["rs"],                                      line: ["//"], block: [("/*", "*/")]),
        lang("C/C++",      ["c", "h", "cc", "cpp", "cxx", "hpp", "hh"], line: ["//"], block: [("/*", "*/")]),
        lang("Java",       ["java"],                                    line: ["//"], block: [("/*", "*/")]),
        lang("Kotlin",     ["kt", "kts"],                               line: ["//"], block: [("/*", "*/")]),
        // Dart (Flutter): // and /// line comments, /* */ blocks. Was MISSING, so
        // every .dart file — often the bulk of a mobile app — went uncounted.
        lang("Dart",       ["dart"],                                    line: ["//"], block: [("/*", "*/")]),
        // Ruby's =begin/=end MUST sit at column 0 (blockAtLineStart) — an indented
        // one is a syntax error, not a comment, so it counts as code.
        lang("Ruby",       ["rb"],                                      line: ["#"],  block: [("=begin", "=end")], blockAtLineStart: true),
        lang("PHP",        ["php"],                                     line: ["//", "#"], block: [("/*", "*/")]),
        lang("Scala",      ["scala", "sbt"],                            line: ["//"], block: [("/*", "*/")]),
        lang("Groovy",     ["gradle", "groovy"],                       line: ["//"], block: [("/*", "*/")]),
        lang("Lua",        ["lua"],                                     line: ["--"], block: [("--[[", "]]")]),
        lang("SQL",        ["sql"],                                     line: ["--"], block: [("/*", "*/")]),
        lang("Shell",      ["sh", "bash", "zsh"],                       line: ["#"]),
        lang("Objective-C", ["m", "mm"],                               line: ["//"], block: [("/*", "*/")]),
        lang("C#",         ["cs"],                                      line: ["//"], block: [("/*", "*/")]),
        lang("HTML/XML",   ["html", "htm", "xhtml", "xml", "vue"],      block: [("<!--", "-->")]),
        lang("CSS",        ["css"],                                     block: [("/*", "*/")]),
        lang("Sass/Less",  ["scss", "sass", "less"],                    line: ["//"], block: [("/*", "*/")]),
        lang("YAML",       ["yml", "yaml"],                             line: ["#"]),
        lang("TOML",       ["toml"],                                    line: ["#"]),
        lang("JSON",       ["json"]),                  // no comments -> all non-blank lines are code
        lang("Markdown",   ["md"]),                    // no comments -> all non-blank lines are code
    ]

    /// Derived ext → definition map, MEMOIZED (computed once). Lowercased keys.
    /// First definition wins if two share an extension (none currently do).
    public static let byExtension: [String: LanguageDefinition] = {
        var map: [String: LanguageDefinition] = [:]
        for def in languageTable {
            for ext in def.extensions where map[ext] == nil {
                map[ext.lowercased()] = def
            }
        }
        return map
    }()

    /// Look up the language for a filename/path by its extension (case-insensitive).
    /// Returns nil for unknown/extensionless files (caller decides to skip).
    public static func language(forPath path: String) -> LanguageDefinition? {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : byExtension[ext]
    }

    // MARK: Binary guard

    /// Heuristic binary check: a NUL byte anywhere is the classic "this isn't text"
    /// signal (matches how git/grep decide). Callers skip such files and bump
    /// `CodeStats.skippedBinary` rather than feeding garbage to `classify`.
    public static func isLikelyBinary(_ data: Data) -> Bool {
        data.contains(0)
    }

    // MARK: Classifier

    /// Classify one file's `contents` against a `language`, returning per-line
    /// code/comment/blank counts. Single pass; carries `inBlockComment` state
    /// across lines.
    ///
    /// Rules:
    ///  - blank  = line is empty/whitespace AND we are not inside a block comment.
    ///  - comment = the line is consumed by an open block, OR (outside a block) its
    ///    first non-whitespace token is a line-comment or a block-comment opener and
    ///    no real code follows on that line.
    ///  - CODE WINS: if any non-comment, non-whitespace character appears on the line
    ///    — including code AFTER a block close on the same line (`*/ x()`) or a single
    ///    line `/* … */ code` — the line counts as code.
    ///  - A line that both opens and closes a block inline (`/* … */`) with nothing
    ///    else is a comment; with trailing code it is code.
    ///
    /// HEURISTIC LIMITATION: block delimiters are matched as plain substrings with no
    /// awareness of string/char literals. So `let s = "/*"` can wrongly open a block,
    /// and for Python every triple-quoted STRING LITERAL (docstring or value) is
    /// counted as a comment. This is the standard cloc-style trade-off: cheap, pure,
    /// and good enough for aggregate stats. Documented so callers don't expect a
    /// real lexer.
    public static func classify(contents: String, language: LanguageDefinition) -> FileClassification {
        var code = 0, comment = 0, blank = 0
        var inBlock = false
        var openClose: (open: String, close: String)? = nil   // which block we're inside

        let lineComments = language.comment.lineComment
        let blocks = language.comment.blockComment
        let requireLineStart = language.comment.blockRequiresLineStart

        // splitWholeContent keeps trailing empty line semantics consistent: a file
        // ending in "\n" yields no spurious extra blank line.
        for rawLine in splitLines(contents) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if inBlock {
                // Inside a block: look for this block's close token on the line.
                let close = openClose!.close
                // Column-0-anchored closes (Ruby =end) only count at line start; the
                // whole closing line is then a comment. Others close wherever found.
                let afterClose: Substring? = requireLineStart
                    ? (rawLine.hasPrefix(close) ? "" : nil)
                    : remainderAfterFirst(close, in: rawLine)
                if let afterClose {
                    inBlock = false
                    openClose = nil
                    // Code after the close token on the same line -> the line is CODE.
                    if hasCodeRemaining(afterClose, lineComments: lineComments, blocks: blocks,
                                        requireLineStart: requireLineStart) {
                        code += 1
                    } else {
                        comment += 1
                    }
                } else {
                    // Whole line is still inside the block -> comment (even if blank).
                    comment += 1
                }
                continue
            }

            // Not in a block.
            if trimmed.isEmpty { blank += 1; continue }

            // Classify a non-blank, non-block line: does real code appear before any
            // comment opener? `hasCodeRemaining` answers that and updates block state.
            var localInBlock = false
            if lineIsCode(rawLine, lineComments: lineComments, blocks: blocks,
                          endsInsideBlock: &localInBlock, openedBlock: &openClose,
                          requireLineStart: requireLineStart) {
                code += 1
            } else {
                comment += 1
            }
            inBlock = localInBlock
        }

        return FileClassification(code: code, comment: comment, blank: blank)
    }

    // MARK: - Line scanning helpers

    /// Split into lines on \n / \r\n, dropping a single trailing newline so a file
    /// ending in "\n" doesn't report a phantom final blank line. We normalize CRLF
    /// to LF up front because Swift's `split(separator:)` treats "\r\n" as ONE
    /// grapheme (so it won't break on the embedded "\n").
    private static func splitLines(_ s: String) -> [Substring] {
        let normalized = s.replacingOccurrences(of: "\r\n", with: "\n")
        var body = Substring(normalized)
        if body.hasSuffix("\n") { body = body.dropLast() }
        if body.isEmpty { return [] }
        return body.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Scan a non-blank line that begins OUTSIDE any block. Walks left→right; the
    /// FIRST thing it meets decides:
    ///  - real (non-whitespace) char that isn't a comment opener -> CODE for the
    ///    whole line (we still must track a block that opens later, e.g. `x() /* …`).
    ///  - line-comment token first -> comment (rest of line ignored).
    ///  - block-open token first -> consume the block; if it closes on this line with
    ///    trailing code -> CODE, else comment, and set `endsInsideBlock` if unclosed.
    /// Returns true when the line should count as CODE. Sets `openedBlock` to the
    /// open/close pair when the line ends inside an unterminated block.
    private static func lineIsCode(_ line: Substring,
                                   lineComments: [String],
                                   blocks: [(open: String, close: String)],
                                   endsInsideBlock: inout Bool,
                                   openedBlock: inout (open: String, close: String)?,
                                   requireLineStart: Bool = false) -> Bool {
        var idx = line.startIndex
        let end = line.endIndex
        var sawCode = false

        while idx < end {
            let ch = line[idx]
            if ch == " " || ch == "\t" { idx = line.index(after: idx); continue }

            // Line comment opener at this position (only matters if no code yet).
            if !sawCode, let tok = matchToken(lineComments, in: line, at: idx) {
                _ = tok
                return false   // comment line
            }

            // Block opener at this position. A column-0-anchored opener (Ruby =begin)
            // only counts when nothing was skipped before it — an indented =begin is
            // code, not a comment.
            if (!requireLineStart || idx == line.startIndex),
               let blk = matchBlock(blocks, in: line, at: idx) {
                let afterOpen = line.index(idx, offsetBy: blk.open.count)
                // Does the matching close appear later on THIS line?
                if let rangeAfterClose = remainderAfterFirstIndexed(blk.close, in: line, from: afterOpen) {
                    // Block closed inline; keep scanning what follows the close.
                    if hasCodeRemaining(line[rangeAfterClose...], lineComments: lineComments, blocks: blocks) {
                        return true
                    }
                    // Nothing meaningful after the close: if no prior code, it's a
                    // comment line; otherwise code already decided it.
                    if sawCode { return true }
                    return false
                } else {
                    // Block opens here and runs to EOL -> remainder is inside a block.
                    endsInsideBlock = true
                    openedBlock = blk
                    return sawCode    // code before the opener -> code line; else comment
                }
            }

            // A real code character.
            sawCode = true
            idx = line.index(after: idx)
        }
        return sawCode
    }

    /// True if `slice` (the tail after a block close) contains any real code —
    /// ignoring leading whitespace, line comments, and further inline block comments.
    /// Used both for "code after */ on the same line" and the in-block close case.
    private static func hasCodeRemaining(_ slice: Substring,
                                         lineComments: [String],
                                         blocks: [(open: String, close: String)],
                                         requireLineStart: Bool = false) -> Bool {
        var dummyBlock = false
        var dummyOpen: (open: String, close: String)? = nil
        if slice.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return lineIsCode(slice, lineComments: lineComments, blocks: blocks,
                          endsInsideBlock: &dummyBlock, openedBlock: &dummyOpen,
                          requireLineStart: requireLineStart)
    }

    // MARK: Token matching

    /// If any token in `tokens` is a prefix of `line` at `idx`, return it (longest
    /// match wins so `///` style longer tokens beat `/`). nil otherwise.
    private static func matchToken(_ tokens: [String], in line: Substring,
                                   at idx: Substring.Index) -> String? {
        var best: String? = nil
        for tok in tokens where line[idx...].hasPrefix(tok) {
            if best == nil || tok.count > best!.count { best = tok }
        }
        return best
    }

    /// Like `matchToken` but for block pairs; returns the matched (open, close).
    private static func matchBlock(_ blocks: [(open: String, close: String)], in line: Substring,
                                   at idx: Substring.Index) -> (open: String, close: String)? {
        var best: (open: String, close: String)? = nil
        for blk in blocks where line[idx...].hasPrefix(blk.open) {
            if best == nil || blk.open.count > best!.open.count { best = blk }
        }
        return best
    }

    /// Find the first occurrence of `token` in `line` and return the substring AFTER
    /// it. Used for the "inside a block, where does it close" case. nil if absent.
    private static func remainderAfterFirst(_ token: String, in line: Substring) -> Substring? {
        guard let r = line.range(of: token) else { return nil }
        return line[r.upperBound...]
    }

    /// Like `remainderAfterFirst` but searching only from `from`; returns the range
    /// (upperBound...) so the caller can slice the original line. nil if absent.
    private static func remainderAfterFirstIndexed(_ token: String, in line: Substring,
                                                   from: Substring.Index) -> Substring.Index? {
        guard let r = line.range(of: token, range: from..<line.endIndex) else { return nil }
        return r.upperBound
    }
}
