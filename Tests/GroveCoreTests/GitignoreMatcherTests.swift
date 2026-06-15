import XCTest
@testable import GroveCore

final class GitignoreMatcherTests: XCTestCase {

    // MARK: - Single-pattern table

    /// One row: a single pattern, a path + isDirectory, and whether the path is
    /// ignored. Drives the bulk of the anchoring / glob / dir-only coverage.
    private struct Row {
        let pattern: String
        let path: String
        let isDir: Bool
        let expected: Bool
        let note: String
        init(_ pattern: String, _ path: String, dir: Bool = false,
             _ expected: Bool, _ note: String = "") {
            self.pattern = pattern; self.path = path; self.isDir = dir
            self.expected = expected; self.note = note
        }
    }

    func testSinglePatternTable() {
        let rows: [Row] = [
            // --- floating basename: matches at any depth ---
            Row("build", "build", true, "floating dir matches at root"),
            Row("build", "src/build", true, "floating dir matches nested"),
            Row("build", "src/build/out.o", dir: false, true, "ancestor dir match ignores descendants"),
            Row("foo.log", "a/b/foo.log", true, "floating file matches deep"),
            Row("foo.log", "a/b/foo.logx", false, "no partial-component match"),

            // --- anchored: leading slash pins to root ---
            Row("/build", "build", true, "anchored matches at root"),
            Row("/build", "src/build", false, "anchored does NOT match nested"),

            // --- internal slash anchors (no leading slash needed) ---
            Row("src/build", "src/build", true, "internal slash anchors to root"),
            Row("src/build", "x/src/build", false, "internal-slash pattern is rooted"),
            Row("a/b", "a/b", true, "two-component anchored hit"),
            Row("a/b", "a/c", false, "two-component anchored miss"),

            // --- *.ext glob (star never crosses '/') ---
            Row("*.log", "error.log", true, "star matches basename ext at root"),
            Row("*.log", "deep/dir/error.log", true, "floating *.log matches deep"),
            Row("*.log", "error.txt", false, "wrong ext -> no match"),
            Row("*.log", "logs/error", false, "star is not the whole path"),
            Row("a*c", "abc", true, "star matches middle run"),
            Row("a*c", "ac", true, "star matches zero chars"),
            Row("a*c", "a/c", false, "star never crosses slash"),

            // --- ? matches exactly one non-slash char ---
            Row("file?.txt", "file1.txt", true, "question matches one char"),
            Row("file?.txt", "file.txt", false, "question needs exactly one"),
            Row("file?.txt", "file12.txt", false, "question is not two"),
            Row("a?b", "a/b", false, "question never crosses slash"),

            // --- directory-only (trailing slash) ---
            Row("logs/", "logs", dir: true, true, "dir-only matches a directory"),
            Row("logs/", "logs", dir: false, false, "dir-only ignores a file of same name"),
            Row("logs/", "src/logs", dir: true, true, "dir-only floats to any depth"),

            // --- leading **/ : any depth ---
            Row("**/foo", "foo", true, "leading **/ matches at root (zero dirs)"),
            Row("**/foo", "a/foo", true, "leading **/ matches one dir deep"),
            Row("**/foo", "a/b/c/foo", true, "leading **/ matches many dirs deep"),
            Row("**/foo", "a/foobar", false, "leading **/ still needs exact component"),

            // --- trailing /** : everything inside ---
            Row("abc/**", "abc/x", true, "trailing /** matches a child"),
            Row("abc/**", "abc/x/y/z", true, "trailing /** matches a deep descendant"),
            Row("abc/**", "abc", dir: true, false, "trailing /** does NOT match the dir itself"),
            Row("abc/**", "abcd/x", false, "trailing /** anchored to abc only"),

            // --- middle a/**/b : zero+ intermediate dirs ---
            Row("a/**/b", "a/b", true, "middle ** allows zero intermediates"),
            Row("a/**/b", "a/x/b", true, "middle ** allows one intermediate"),
            Row("a/**/b", "a/x/y/b", true, "middle ** allows many intermediates"),
            Row("a/**/b", "a/x/c", false, "middle ** still needs trailing b"),
            Row("a/**/b", "z/a/b", false, "a/**/b is rooted at a"),
        ]

        for r in rows {
            let rules = GitignoreRules(contents: r.pattern)
            let got = rules.match(relativePath: r.path, isDirectory: r.isDir)
            XCTAssertEqual(got, r.expected,
                           "pattern=\(r.pattern) path=\(r.path) dir=\(r.isDir) — \(r.note)")
        }
    }

    // MARK: - Parsing edge cases (comments, escapes, trailing ws, negation flags)

    func testBlankAndCommentLinesProduceNoRules() {
        let rules = GitignoreRules(contents: """

        # a comment line
        *.tmp
        """)
        XCTAssertEqual(rules.patterns.count, 1, "blank + comment dropped, one real rule")
        XCTAssertTrue(rules.match(relativePath: "x.tmp", isDirectory: false))
    }

    func testEscapedHashIsLiteralPattern() {
        // `\#` -> a literal pattern named "#tag".
        let rules = GitignoreRules(contents: "\\#tag")
        XCTAssertEqual(rules.patterns.count, 1)
        XCTAssertTrue(rules.match(relativePath: "#tag", isDirectory: false))
        XCTAssertFalse(rules.match(relativePath: "tag", isDirectory: false))
    }

    func testEscapedBangIsLiteralNotNegation() {
        // `\!` -> literal "!important", NOT a negation.
        let rules = GitignoreRules(contents: "\\!important")
        XCTAssertEqual(rules.patterns.count, 1)
        XCTAssertFalse(rules.patterns[0].negated)
        XCTAssertTrue(rules.match(relativePath: "!important", isDirectory: false))
    }

    func testTrailingWhitespaceIsStripped() {
        // "foo   " -> pattern "foo"; trailing spaces are not part of the match.
        let rules = GitignoreRules(contents: "foo   ")
        XCTAssertTrue(rules.match(relativePath: "foo", isDirectory: false))
        XCTAssertFalse(rules.match(relativePath: "foo ", isDirectory: false))
    }

    func testEscapedTrailingSpaceIsKept() {
        // "foo\ " keeps ONE literal trailing space, so it matches "foo " only.
        let rules = GitignoreRules(contents: "foo\\ ")
        XCTAssertTrue(rules.match(relativePath: "foo ", isDirectory: false))
        XCTAssertFalse(rules.match(relativePath: "foo", isDirectory: false))
    }

    func testDoubleBackslashBeforeTrailingSpaceStripsSpace() {
        // "foo\\ " — the `\\` is a LITERAL backslash, so the trailing space is NOT
        // escaped and git strips it: the pattern matches "foo\" (one backslash),
        // never "foo " or "foo". Counting a single backslash wrongly kept the space.
        let rules = GitignoreRules(contents: "foo\\\\ ")
        XCTAssertTrue(rules.match(relativePath: "foo\\", isDirectory: false),
                      "matches foo + one literal backslash")
        XCTAssertFalse(rules.match(relativePath: "foo ", isDirectory: false),
                       "the trailing space was unescaped and stripped")
        XCTAssertFalse(rules.match(relativePath: "foo", isDirectory: false),
                       "the literal backslash is part of the name")
    }

    func testCommentMarkerOnlyAtLineStart() {
        // A '#' that is not the first char is a literal character.
        let rules = GitignoreRules(contents: "a#b")
        XCTAssertEqual(rules.patterns.count, 1)
        XCTAssertTrue(rules.match(relativePath: "a#b", isDirectory: false))
    }

    // MARK: - Last-match-wins / negation order

    func testNegationReincludesWhenItIsTheLastMatch() {
        // Exclude the CONTENTS of build/ (build/*, NOT the directory itself), then
        // re-include keep.txt. git honors the re-include only because the directory is
        // not pruned; `build/` (dir-excluded) would forbid it — verified against real
        // git, see testNegationCannotReincludeUnderExcludedDirectory.
        let rules = GitignoreRules(contents: """
        build/*
        !build/keep.txt
        """)
        XCTAssertTrue(rules.match(relativePath: "build/other.txt", isDirectory: false))
        XCTAssertFalse(rules.match(relativePath: "build/keep.txt", isDirectory: false),
                       "later !pattern re-includes when only the contents are excluded")
    }

    func testNegationOrderMatters_lastWins() {
        // !*.log first, then *.log: the LATER ignore wins -> ignored.
        let reIncludeThenIgnore = GitignoreRules(contents: """
        !*.log
        *.log
        """)
        XCTAssertTrue(reIncludeThenIgnore.match(relativePath: "a.log", isDirectory: false),
                      "last (ignore) wins")

        // *.log first, then !*.log: the LATER re-include wins -> NOT ignored.
        let ignoreThenReInclude = GitignoreRules(contents: """
        *.log
        !*.log
        """)
        XCTAssertFalse(ignoreThenReInclude.match(relativePath: "a.log", isDirectory: false),
                       "last (re-include) wins")
    }

    func testDecisionDistinguishesUnmatchedFromReincluded() {
        let rules = GitignoreRules(contents: """
        *.log
        !keep.log
        """)
        XCTAssertEqual(rules.decide(relativePath: "x.log", isDirectory: false), .ignored)
        XCTAssertEqual(rules.decide(relativePath: "keep.log", isDirectory: false), .included)
        XCTAssertEqual(rules.decide(relativePath: "main.swift", isDirectory: false), .unmatched)
    }

    // MARK: - Scope stacking (deepest-first precedence)

    func testScopeDeeperFileReincludesAgainstShallowerIgnore() {
        // Root ignores *.log everywhere; a nested .gitignore re-includes keep.log.
        var scope = GitignoreScope()
        scope.push(.init(directory: "", rules: GitignoreRules(contents: "*.log")))
        scope.push(.init(directory: "src", rules: GitignoreRules(contents: "!keep.log")))

        // Deepest scope (src) re-includes src/keep.log.
        XCTAssertFalse(scope.isIgnored(path: "src/keep.log", isDirectory: false),
                       "deeper !keep.log overrides root ignore")
        // A different .log under src is still caught by the root rule (deeper scope
        // is unmatched -> falls through).
        XCTAssertTrue(scope.isIgnored(path: "src/other.log", isDirectory: false))
        // Outside src, only the root rule applies.
        XCTAssertTrue(scope.isIgnored(path: "top.log", isDirectory: false))
    }

    func testScopeFrameOnlySeesPathsUnderItsDirectory() {
        var scope = GitignoreScope()
        scope.push(.init(directory: "", rules: GitignoreRules(contents: "node_modules/")))
        scope.push(.init(directory: "web", rules: GitignoreRules(contents: "dist/")))

        // web/dist matched by the web frame.
        XCTAssertTrue(scope.isIgnored(path: "web/dist", isDirectory: true))
        // api/dist is NOT under web -> web frame skipped; root has no rule for it.
        XCTAssertFalse(scope.isIgnored(path: "api/dist", isDirectory: true))
        // node_modules anywhere caught by root frame.
        XCTAssertTrue(scope.isIgnored(path: "web/node_modules", isDirectory: true))
    }

    func testScopePopRestoresPreviousFrames() {
        var scope = GitignoreScope()
        scope.push(.init(directory: "", rules: GitignoreRules(contents: "*.log")))
        scope.push(.init(directory: "src", rules: GitignoreRules(contents: "!keep.log")))
        XCTAssertFalse(scope.isIgnored(path: "src/keep.log", isDirectory: false))

        scope.pop()   // leave src
        // Without the src frame, the root *.log rule now ignores keep.log too.
        XCTAssertTrue(scope.isIgnored(path: "src/keep.log", isDirectory: false))
    }

    // MARK: - .ignorestats parses with identical syntax

    func testIgnorestatsUsesSameParser() {
        // The spec: .ignorestats is parsed by the same type. Sanity-check a couple
        // of rows through GitignoreRules directly.
        let rules = GitignoreRules(contents: """
        # generated
        *.pb.go
        vendor/
        !vendor/keepme.go
        """)
        XCTAssertTrue(rules.match(relativePath: "api/service.pb.go", isDirectory: false))
        XCTAssertTrue(rules.match(relativePath: "vendor", isDirectory: true))
        // git: `!vendor/keepme.go` CANNOT re-include a file once `vendor/` excludes the
        // directory itself — verified against real `git check-ignore`. So it stays
        // ignored (NOT re-included). The contrast (`vendor/*` form) is below.
        XCTAssertTrue(rules.match(relativePath: "vendor/keepme.go", isDirectory: false))
    }

    // MARK: - Parent-exclusion rule (a negation can't re-include under an excluded dir)

    func testNegationCannotReincludeUnderExcludedDirectory() {
        // `dir/` excludes the DIRECTORY → no later `!dir/keep` re-includes a file in it
        // (git never recurses into a pruned dir). Verified against real git.
        let excludedDir = GitignoreRules(contents: "build/\n!build/keep.txt\n")
        XCTAssertTrue(excludedDir.match(relativePath: "build/keep.txt", isDirectory: false))
        XCTAssertTrue(excludedDir.match(relativePath: "build/other.txt", isDirectory: false))

        // `dir/*` excludes only the CONTENTS, leaving the directory itself includable,
        // so `!dir/keep` DOES re-include — the git-documented working idiom.
        let excludedContents = GitignoreRules(contents: "build/*\n!build/keep.txt\n")
        XCTAssertFalse(excludedContents.match(relativePath: "build/keep.txt", isDirectory: false))
        XCTAssertTrue(excludedContents.match(relativePath: "build/other.txt", isDirectory: false))

        // A re-included intervening directory (`!build/`) clears the prune so a deeper
        // file is reachable again.
        let reincludedDir = GitignoreRules(contents: "build/\n!build/\nbuild/*.tmp\n")
        XCTAssertFalse(reincludedDir.match(relativePath: "build/app.js", isDirectory: false))
        XCTAssertTrue(reincludedDir.match(relativePath: "build/app.tmp", isDirectory: false))
    }

    func testCrossScopeNegationCannotReincludeUnderShallowerExcludedDir() {
        // A shallow scope excludes the DIRECTORY `gen/`; a deeper scope inside it tries
        // to re-include a file. git forbids that (parent dir pruned), so it stays
        // ignored — even though the deeper frame's own decision is `.included`.
        var scope = GitignoreScope()
        scope.push(.init(directory: "", rules: GitignoreRules(contents: "gen/")))
        scope.push(.init(directory: "gen", rules: GitignoreRules(contents: "!keep.swift")))
        XCTAssertTrue(scope.isIgnored(path: "gen/keep.swift", isDirectory: false))

        // Contrast: shallow scope excludes only the CONTENTS (`gen/*`), so the deeper
        // re-include is honored.
        var scope2 = GitignoreScope()
        scope2.push(.init(directory: "", rules: GitignoreRules(contents: "gen/*")))
        scope2.push(.init(directory: "gen", rules: GitignoreRules(contents: "!keep.swift")))
        XCTAssertFalse(scope2.isIgnored(path: "gen/keep.swift", isDirectory: false))
    }
}
