import XCTest
@testable import GroveCore

final class GraphTests: XCTestCase {

    // MARK: parseNumstat (commit file changes)

    func testParseNumstatTabSeparatedWithBinary() {
        let out = "15\t2\tSources/A.swift\n0\t9\tSources/B.swift\n-\t-\tassets/logo.png\n"
        let changes = GitService.parseNumstat(out)
        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(changes[0], CommitFileChange(path: "Sources/A.swift", additions: 15, deletions: 2))
        XCTAssertEqual(changes[1].deletions, 9)
        XCTAssertTrue(changes[2].isBinary)               // "-\t-" → binary
        XCTAssertEqual(changes[2].path, "assets/logo.png")
    }

    func testParseNumstatIgnoresBlankAndMalformedLines() {
        XCTAssertTrue(GitService.parseNumstat("\n  \nnotnumstat\n").isEmpty)
    }

    func testParseNumstatResolvesRenamesToNewPath() {
        // `git show --numstat` renders renames as `{old => new}` (the real
        // output of commit 0d68daa); the file list should show only the new path.
        let out = "15\t13\tSources/GroveAppKit/Views/{CreateWorkspaceSheet.swift => CreateWorkspaceScreen.swift}\n"
            + "49\t108\tSources/GroveAppKit/Views/{SettingsSheet.swift => ProjectSettingsScreen.swift}\n"
            + "5\t1\t{old.txt => new.txt}\n"
            + "2\t0\tSources/Plain.swift\n"
        let changes = GitService.parseNumstat(out)
        XCTAssertEqual(changes.map(\.path), [
            "Sources/GroveAppKit/Views/CreateWorkspaceScreen.swift",
            "Sources/GroveAppKit/Views/ProjectSettingsScreen.swift",
            "new.txt",
            "Sources/Plain.swift",
        ])
    }

    func testRenamedNewPathHandlesDirectoryRename() {
        // Directory renames keep the surrounding segments: `a/{x => y}/f` → `a/y/f`.
        XCTAssertEqual(GitService.renamedNewPath("a/{old => new}/file.swift"), "a/new/file.swift")
        XCTAssertEqual(GitService.renamedNewPath("plain/path.swift"), "plain/path.swift")
    }

    func testRenamedNewPathHandlesWholePathRenameWithoutBraces() {
        // With NO common prefix git emits the bare `old => new` (no braces); the file
        // list must show only the new path, not the literal "old => new" string.
        XCTAssertEqual(GitService.renamedNewPath("oldname.swift => newname.swift"), "newname.swift")
        XCTAssertEqual(GitService.renamedNewPath("src/a/old.txt => docs/b/new.txt"), "docs/b/new.txt")
        // And end to end through the numstat parser.
        let changes = GitService.parseNumstat("4\t2\told/path.swift => new/path.swift\n")
        XCTAssertEqual(changes.map(\.path), ["new/path.swift"])
    }

    // MARK: layoutLanes (pure)

    private func raw(_ hash: String, parents: [String]) -> RawCommit {
        RawCommit(hash: hash, parents: parents, author: "t",
                  date: Date(timeIntervalSince1970: 0), refs: [], subject: hash)
    }

    func testLinearHistoryStaysOnLaneZero() {
        let nodes = layoutLanes([
            raw("c3", parents: ["c2"]),
            raw("c2", parents: ["c1"]),
            raw("c1", parents: []),
        ])
        XCTAssertEqual(nodes.map(\.hash), ["c3", "c2", "c1"], "input order preserved")
        XCTAssertEqual(nodes.map(\.lane), [0, 0, 0])
    }

    func testForkAndMergeOpensLaneOneThenClosesIt() {
        // M merges m2 (lane 0) and s1 (lane 1). At the fork point c0 both lanes
        // expect c0; c0 takes lane 0 and lane 1 must CLOSE — proven by the
        // unrelated root r that follows reusing lane 1 instead of opening lane 2.
        let nodes = layoutLanes([
            raw("M",  parents: ["m2", "s1"]),
            raw("m2", parents: ["c0"]),
            raw("s1", parents: ["c0"]),
            raw("c0", parents: ["z"]),
            raw("r",  parents: []),
            raw("z",  parents: []),
        ])
        XCTAssertEqual(nodes.map(\.lane), [0, 0, 1, 0, 1, 0])
    }

    func testOctopusMergeOpensThreeLanes() {
        let nodes = layoutLanes([
            raw("O", parents: ["a", "b", "c"]),
            raw("a", parents: ["r"]),
            raw("b", parents: ["r"]),
            raw("c", parents: ["r"]),
            raw("r", parents: []),
        ])
        XCTAssertEqual(nodes.map(\.lane), [0, 0, 1, 2, 0])
    }

    // MARK: parser (pure, internal via @testable)

    func testParseCommitLogTabSeparatedWithRefsAndEmptyFields() {
        let line1 = "aaa\tbbb ccc\tAlice\t2026-06-10T12:00:00+03:00\tHEAD -> main, tag: v1.0, origin/main\tMerge things"
        let line2 = "bbb\t\tBob\t2026-06-10T11:00:00Z\t\tplain commit"
        let commits = parseCommitLog(line1 + "\n" + line2 + "\n")
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].hash, "aaa")
        XCTAssertEqual(commits[0].parents, ["bbb", "ccc"])
        XCTAssertEqual(commits[0].author, "Alice")
        XCTAssertEqual(commits[0].refs, ["HEAD -> main", "tag: v1.0", "origin/main"])
        XCTAssertEqual(commits[0].subject, "Merge things")
        XCTAssertEqual(commits[0].date, ISO8601DateFormatter().date(from: "2026-06-10T12:00:00+03:00"))
        XCTAssertEqual(commits[1].parents, [], "root commit has empty parents field")
        XCTAssertEqual(commits[1].refs, [], "empty %D -> empty refs")
        XCTAssertEqual(commits[1].subject, "plain commit")
    }

    // MARK: commitGraph on a real repo with a merge commit

    func testCommitGraphParsesMergeCommitFixture() async throws {
        let tmp = try Fixture.tempDir("git-graph")
        let repo = try Fixture.makeRepo(in: tmp, name: "repo") // main @ commit "base"

        try Fixture.sh("git checkout -q -b side", cwd: repo)
        try Fixture.commit(repo: repo, file: "side.txt", content: "s", message: "side work")
        try Fixture.sh("git checkout -q main", cwd: repo)
        try Fixture.commit(repo: repo, file: "main.txt", content: "m", message: "main work")
        try Fixture.sh("git merge --no-ff -m 'merge side' side", cwd: repo)

        let mergeHash = try Fixture.sh("git rev-parse HEAD", cwd: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sideHash = try Fixture.sh("git rev-parse side", cwd: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let git = GitService()
        let nodes = try await git.commitGraph(repoPath: repo.path)

        XCTAssertEqual(nodes.count, 4)

        // Topo order: the merge commit leads (newest, no children) and sits on lane 0.
        let merge = try XCTUnwrap(nodes.first)
        XCTAssertEqual(merge.hash, mergeHash)
        XCTAssertEqual(merge.parents.count, 2)
        XCTAssertEqual(merge.subject, "merge side")
        XCTAssertEqual(merge.lane, 0)
        XCTAssertTrue(merge.refs.contains("HEAD -> main"), "got refs: \(merge.refs)")

        let sideNode = try XCTUnwrap(nodes.first { $0.hash == sideHash })
        XCTAssertEqual(sideNode.refs, ["side"])
        XCTAssertEqual(sideNode.subject, "side work")
        XCTAssertEqual(sideNode.author, "t")

        let root = try XCTUnwrap(nodes.last)
        XCTAssertEqual(root.subject, "base")
        XCTAssertEqual(root.parents, [])
        XCTAssertGreaterThanOrEqual(merge.date, root.date)

        // limit/skip paging keeps topo order.
        let page = try await git.commitGraph(repoPath: repo.path, limit: 2, skip: 1)
        XCTAssertEqual(page.map(\.hash), [nodes[1].hash, nodes[2].hash])
    }
}
