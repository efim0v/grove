import XCTest
import GroveCore
import GroveAppKit

final class TreeModelBadgesTests: XCTestCase {

    // MARK: - relativeAge

    func testRelativeAgeMinutes() {
        XCTAssertEqual(relativeAge(Fix.now.addingTimeInterval(-300), now: Fix.now), "5m")
    }

    func testRelativeAgeClampsZeroAndFutureDates() {
        XCTAssertEqual(relativeAge(Fix.now, now: Fix.now), "0m")
        XCTAssertEqual(relativeAge(Fix.now.addingTimeInterval(600), now: Fix.now), "0m")
    }

    func testRelativeAgeHourBoundary() {
        XCTAssertEqual(relativeAge(Fix.now.addingTimeInterval(-3_599), now: Fix.now), "59m")
        XCTAssertEqual(relativeAge(Fix.now.addingTimeInterval(-3_600), now: Fix.now), "1h")
        XCTAssertEqual(relativeAge(Fix.now.addingTimeInterval(-3 * 3_600), now: Fix.now), "3h")
    }

    func testRelativeAgeDayBoundary() {
        XCTAssertEqual(relativeAge(Fix.now.addingTimeInterval(-23 * 3_600), now: Fix.now), "23h")
        XCTAssertEqual(relativeAge(Fix.now.addingTimeInterval(-Fix.days(2)), now: Fix.now), "2d")
    }

    func testRelativeAgeWeekBoundary() {
        XCTAssertEqual(relativeAge(Fix.now.addingTimeInterval(-Fix.days(6.5)), now: Fix.now), "6d")
        XCTAssertEqual(relativeAge(Fix.now.addingTimeInterval(-Fix.days(7)), now: Fix.now), "1w")
        XCTAssertEqual(relativeAge(Fix.now.addingTimeInterval(-Fix.days(35)), now: Fix.now), "5w")
    }

    // MARK: - ClaudeActivity

    func testActivityMapsBusyAndWaitingEverythingElseIdle() {
        XCTAssertEqual(ClaudeActivity(status: "busy"), .busy)
        XCTAssertEqual(ClaudeActivity(status: "waiting"), .waiting)
        XCTAssertEqual(ClaudeActivity(status: "idle"), .idle)
        XCTAssertEqual(ClaudeActivity(status: "shell"), .idle)
        XCTAssertEqual(ClaudeActivity(status: "some-future-status"), .idle)
    }

    // MARK: - badges(for:now:)

    func testAgeDaysIsMaxForkAgeAcrossRepos() {
        let ws = Fix.workspace(name: "w", repos: [
            Fix.repoState(dirName: "a", forkDate: Fix.now.addingTimeInterval(-Fix.days(2))),
            Fix.repoState(dirName: "b", forkDate: Fix.now.addingTimeInterval(-Fix.days(5))),
        ])
        let result = badges(for: ws, now: Fix.now)
        XCTAssertEqual(result.ageDays, 5)
        XCTAssertEqual(result.ageBucket, .fresh)
    }

    func testAgeBucketBoundaries() {
        func bucket(daysOld: Double) -> AgeBucket {
            let ws = Fix.workspace(name: "w", repos: [
                Fix.repoState(forkDate: Fix.now.addingTimeInterval(-Fix.days(daysOld))),
            ])
            return badges(for: ws, now: Fix.now).ageBucket
        }
        XCTAssertEqual(bucket(daysOld: 0), .fresh)
        XCTAssertEqual(bucket(daysOld: 6.9), .fresh)
        XCTAssertEqual(bucket(daysOld: 7), .aging)
        XCTAssertEqual(bucket(daysOld: 20.9), .aging)
        XCTAssertEqual(bucket(daysOld: 21), .stale)
        XCTAssertEqual(bucket(daysOld: 400), .stale)
    }

    func testNoForkDatesMeansUnknownBucketAndNilAge() {
        let ws = Fix.workspace(name: "w", repos: [
            Fix.repoState(dirName: "a", forkDate: nil),
            Fix.repoState(dirName: "b", hasMeta: false),
        ])
        let result = badges(for: ws, now: Fix.now)
        XCTAssertNil(result.ageDays)
        XCTAssertEqual(result.ageBucket, .unknown)
    }

    func testDirtyTotalSumsReposAndSkipsMissingMeta() {
        let ws = Fix.workspace(name: "w", repos: [
            Fix.repoState(dirName: "a", dirty: 3),
            Fix.repoState(dirName: "b", dirty: 4),
            Fix.repoState(dirName: "c", hasMeta: false),
        ])
        XCTAssertEqual(badges(for: ws, now: Fix.now).dirtyTotal, 7)
    }

    func testLiveAndResumableCounts() {
        let ws = Fix.workspace(
            name: "w",
            sessions: [Fix.session(id: "s1"), Fix.session(id: "s2"), Fix.session(id: "s3")],
            live: [
                Fix.live(pid: 1, sessionId: "s1", status: "busy"),
                Fix.live(pid: 2, sessionId: "s2", status: "waiting"),
                Fix.live(pid: 3, sessionId: "x9", status: "busy"),   // transcript elsewhere
                Fix.live(pid: 4, sessionId: "x8", status: "shell"),  // idle: counted nowhere
            ])
        let result = badges(for: ws, now: Fix.now)
        XCTAssertEqual(result.busyCount, 2)
        XCTAssertEqual(result.waitingCount, 1)
        // s1 and s2 are live; only s3 has no live process.
        XCTAssertEqual(result.resumableCount, 1)
    }

    func testFreshSessionExcludedFromResumableByCwd() {
        // A fresh live process (empty sessionId) at a session's cwd means that
        // session is running — NOT resumable. A different session elsewhere stays resumable.
        let ws = Fix.workspace(
            name: "w",
            sessions: [Fix.session(id: "fresh", cwd: "/ws/feature"),
                       Fix.session(id: "closed", cwd: "/ws/other")],
            live: [Fix.live(pid: 5, sessionId: "", status: "busy", cwd: "/ws/feature")])
        let r = badges(for: ws, now: Fix.now)
        XCTAssertEqual(r.busyCount, 1)
        XCTAssertEqual(r.resumableCount, 1)   // only "closed" is resumable
    }

    func testSessionSharingWorktreeWithLiveOneStaysResumable() {
        // The cwd exclusion must NOT catch a session that merely shares a worktree
        // with a DIFFERENT (id-matched) live session.
        let ws = Fix.workspace(
            name: "w",
            sessions: [Fix.session(id: "live1", cwd: "/ws/feature"),
                       Fix.session(id: "other", cwd: "/ws/feature")],
            live: [Fix.live(pid: 1, sessionId: "live1", status: "busy", cwd: "/ws/feature")])
        let r = badges(for: ws, now: Fix.now)
        XCTAssertEqual(r.busyCount, 1)
        XCTAssertEqual(r.resumableCount, 1)   // "other" stays resumable
    }

    func testBadgeDedupsRepeatedProcess() {
        let ws = Fix.workspace(
            name: "w", sessions: [Fix.session(id: "s1")],
            live: [Fix.live(pid: 7, sessionId: "s1", status: "busy"),
                   Fix.live(pid: 7, sessionId: "s1", status: "busy")])   // same process twice
        XCTAssertEqual(badges(for: ws, now: Fix.now).busyCount, 1)
    }

    func testEmptyWorkspaceHasAllZeroBadges() {
        let ws = Fix.workspace(name: "w", repos: [])
        XCTAssertEqual(badges(for: ws, now: Fix.now),
                       WorkspaceBadges(ageDays: nil, ageBucket: .unknown, dirtyTotal: 0,
                                       busyCount: 0, waitingCount: 0, resumableCount: 0))
    }
}
