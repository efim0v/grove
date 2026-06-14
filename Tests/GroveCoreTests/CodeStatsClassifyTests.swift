import XCTest
@testable import GroveCore

final class CodeStatsClassifyTests: XCTestCase {

    // Look up a shipped language by extension; fail loudly if the table loses it.
    private func lang(_ ext: String) throws -> LanguageDefinition {
        try XCTUnwrap(CodeStatsEngine.byExtension[ext], "language table is missing .\(ext)")
    }

    /// Classify `source` for the language of `ext` and assert (code, comment, blank).
    private func assertCounts(_ ext: String, _ source: String,
                              code: Int, comment: Int, blank: Int,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let c = CodeStatsEngine.classify(contents: source, language: try lang(ext))
        XCTAssertEqual(c.code, code, "code mismatch", file: file, line: line)
        XCTAssertEqual(c.comment, comment, "comment mismatch", file: file, line: line)
        XCTAssertEqual(c.blank, blank, "blank mismatch", file: file, line: line)
    }

    // MARK: - Language table integrity

    func testLanguageTableMapsExpectedExtensions() throws {
        XCTAssertEqual(try lang("swift").name, "Swift")
        XCTAssertEqual(try lang("tsx").name, "TypeScript/JavaScript")
        XCTAssertEqual(try lang("py").name, "Python")
        XCTAssertEqual(try lang("rs").name, "Rust")
        XCTAssertEqual(try lang("hpp").name, "C/C++")
        XCTAssertEqual(try lang("rb").name, "Ruby")
        XCTAssertEqual(try lang("zsh").name, "Shell")
        XCTAssertEqual(try lang("mm").name, "Objective-C")
        XCTAssertEqual(try lang("json").name, "JSON")
        XCTAssertEqual(try lang("md").name, "Markdown")
        // Lookup is case-insensitive and uses the path extension.
        XCTAssertEqual(CodeStatsEngine.language(forPath: "/a/b/Main.SWIFT")?.name, "Swift")
        XCTAssertNil(CodeStatsEngine.language(forPath: "/a/b/Makefile"))   // no extension
        XCTAssertNil(CodeStatsEngine.language(forPath: "/a/b/data.xyz"))   // unknown ext
    }

    // MARK: - Swift: line comment, multi-line block, code-after-block-close

    func testSwiftLineCommentAndCode() throws {
        try assertCounts("swift", """
        // a leading comment
        let x = 1
        let y = 2 // trailing comment is still CODE
        """, code: 2, comment: 1, blank: 0)
    }

    func testSwiftMultiLineBlockComment() throws {
        // The whole 3-line block (open, middle, close) counts as comment.
        try assertCounts("swift", """
        /* block start
           still inside
           block end */
        let after = 1
        """, code: 1, comment: 3, blank: 0)
    }

    func testSwiftSingleLineBlockComment() throws {
        try assertCounts("swift", """
        /* one line block */
        run()
        """, code: 1, comment: 1, blank: 0)
    }

    func testSwiftCodeAfterBlockCloseOnSameLineIsCode() throws {
        // Line 1 has real code BEFORE the block opens -> code. Line 2 is inside the
        // block but its `*/` is followed by code -> code too. So both lines are CODE.
        try assertCounts("swift", """
        let a = 1 /* opens
        still comment */ let b = 2
        """, code: 2, comment: 0, blank: 0)
    }

    func testSwiftPureBlockCloseThenCodeIsCode() throws {
        // A line that is ENTIRELY inside a block until `*/`, then has code -> code.
        try assertCounts("swift", """
        /* opens
        inner */ let b = 2
        """, code: 1, comment: 1, blank: 0)
    }

    func testSwiftCodeThenBlockOpensToEndOfLine() throws {
        // Real code precedes a block that runs to EOL -> code line, then the next
        // line is inside the block (comment) until it closes.
        try assertCounts("swift", """
        call() /* trailing block
        inside */
        """, code: 1, comment: 1, blank: 0)
    }

    func testSwiftBlanksOutsideBlockAreBlank() throws {
        // NOTE: Swift strips the final newline before `"""`, so this literal has a
        // single trailing blank line, not two.
        try assertCounts("swift", """
        let x = 1

        // c

        """, code: 1, comment: 1, blank: 1)
    }

    func testSwiftBlankLineInsideBlockIsComment() throws {
        // An empty line WHILE inside a block comment counts as comment, not blank.
        try assertCounts("swift", """
        /* open

        close */
        """, code: 0, comment: 3, blank: 0)
    }

    // MARK: - Python: line comment, triple-quote block, shebang

    func testPythonShebangAndHashComment() throws {
        try assertCounts("py", """
        #!/usr/bin/env python
        # a comment
        x = 1
        """, code: 1, comment: 2, blank: 0)
    }

    func testPythonTripleQuoteDocstringIsBlockComment() throws {
        // Triple-quoted block is treated as a comment (documented heuristic).
        try assertCounts("py", """
        \"\"\"
        module docstring
        \"\"\"
        import os
        """, code: 1, comment: 3, blank: 0)
    }

    func testPythonSingleQuoteTripleBlock() throws {
        try assertCounts("py", """
        '''short doc'''
        value = 2
        """, code: 1, comment: 1, blank: 0)
    }

    // MARK: - Ruby: =begin/=end block

    func testRubyBeginEndBlock() throws {
        try assertCounts("rb", """
        =begin
        a multi
        line note
        =end
        puts "hi"
        """, code: 1, comment: 4, blank: 0)
    }

    func testRubyHashComment() throws {
        try assertCounts("rb", """
        # comment
        x = 1
        """, code: 1, comment: 1, blank: 0)
    }

    // MARK: - Shell: line comments only, no block

    func testShellShebangAndComments() throws {
        try assertCounts("sh", """
        #!/bin/bash
        # set things up
        echo hi

        """, code: 1, comment: 2, blank: 0)
    }

    // MARK: - JSON / Markdown: no comments -> every non-blank line is code

    func testJSONAllNonBlankLinesAreCode() throws {
        try assertCounts("json", """
        {
          "a": 1,

          "b": 2
        }
        """, code: 4, comment: 0, blank: 1)
    }

    func testMarkdownHasNoComments() throws {
        // '#' is a Markdown heading, NOT a comment; it must count as code.
        try assertCounts("md", """
        # Title

        Some text.
        """, code: 2, comment: 0, blank: 1)
    }

    // MARK: - TS/JS, Go, C/C++ block + line parity

    func testTypeScriptBlockAndLine() throws {
        try assertCounts("ts", """
        /* header */
        const x = 1; // inline
        /* multi
        line */
        run();
        """, code: 2, comment: 3, blank: 0)
    }

    func testGoCodeAfterBlockClose() throws {
        try assertCounts("go", """
        /* doc */ package main
        func main() {}
        """, code: 2, comment: 0, blank: 0)
    }

    func testCppNestedIshBlockStaysSinglePass() throws {
        // Substring matching has no real nesting: the FIRST */ closes the block, so
        // the trailing `*/` text on the closing line is just code characters.
        try assertCounts("cpp", """
        /* outer /* not-really-nested
        end */ int x = 0;
        """, code: 1, comment: 1, blank: 0)
    }

    // MARK: - Binary guard

    func testIsLikelyBinaryDetectsNulByte() {
        XCTAssertTrue(CodeStatsEngine.isLikelyBinary(Data([0x68, 0x00, 0x69])))     // has NUL
        XCTAssertFalse(CodeStatsEngine.isLikelyBinary(Data("hello\n".utf8)))        // pure text
        XCTAssertFalse(CodeStatsEngine.isLikelyBinary(Data()))                      // empty
    }

    // MARK: - Edge: empty + trailing newline handling

    func testEmptyContentsIsAllZero() throws {
        try assertCounts("swift", "", code: 0, comment: 0, blank: 0)
    }

    func testTrailingNewlineDoesNotAddPhantomBlank() throws {
        // "x\n" is ONE code line, not one code + one blank.
        try assertCounts("swift", "let x = 1\n", code: 1, comment: 0, blank: 0)
    }

    func testCRLFLineEndingsAreSplit() throws {
        let src = "let x = 1\r\n// c\r\n"
        try assertCounts("swift", src, code: 1, comment: 1, blank: 0)
    }
}
