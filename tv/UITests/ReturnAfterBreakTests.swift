import XCTest

/// Playing again after the app was away with the player paused, on a real server's transcode playlist (`plex_timeline=1`), whose
/// playlist spans the whole item, so a seek to its start fetches the item's first segment instead of failing.
@MainActor
final class ReturnAfterBreakTests: PlayerTestCase {
    /// Paused at 3:30, away on the Home screen, back: the transcode is rebuilt paused at 3:30 under a new session, and pressing Play
    /// plays from there instead of from the start of the episode.
    func testPlayAfterReturningToAPausedTranscodePlaysFromThePause() {
        assertPlayAfterReturnPlaysFromThePause(environment: [:])
    }

    /// The same return with the old player's clock reading zero once the app is away (`CRUCIBLE_PLAYER_CLOCK_RESET`, DEBUG only), as after
    /// a night asleep: the paused transport bar still holds that zero and commits it when Play is pressed, which must not take the
    /// viewer back to the start of the episode.
    func testPlayAfterReturningWithAPlayerClockThatLostItsPlacePlaysFromThePause() {
        assertPlayAfterReturnPlaysFromThePause(environment: ["CRUCIBLE_PLAYER_CLOCK_RESET": "1"])
    }

    /// Four hours away with "Rewind After a Break" on and the old clock lost, as on the night this was reported: the transcode comes back
    /// paused fifteen seconds behind the pause (`CRUCIBLE_PLAYER_AWAY_FOR`, DEBUG only), and Play plays from there.
    func testPlayAfterFourHoursAwayPlaysFromBehindThePause() {
        assertPlayAfterReturnPlaysFromThePause(
            environment: ["CRUCIBLE_PLAYER_CLOCK_RESET": "1", "CRUCIBLE_PLAYER_AWAY_FOR": "14400"],
            arguments: ["-rewindAfterBreak", "<true/>"],
            rewindMs: 15_000
        )
    }

    private func assertPlayAfterReturnPlaysFromThePause(environment: [String: String], arguments: [String] = [], rewindMs: Int = 0) {
        setFlags("plex_timeline=1")
        setProgress(Self.episode, seconds: 200)
        let mark = timelineMark()
        let app = launch(playing: Self.episode, arguments: ["-streamingQuality", "8000"] + arguments, environment: environment)
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertTrue(waitForReport(pastMs: 210_000, since: mark, timeout: 40), "playback reaches 3:30: \(timeline(since: mark).map(\.timeMs))")
        TVTest.remote.press(.playPause)
        XCTAssertTrue(waitForReport(Self.episode, state: "paused", since: mark, timeout: 15), "Play/Pause pauses")
        TVTest.settle(3)
        let paused = timeline(since: mark).last { $0.state == "paused" }?.timeMs ?? 0
        let startsBefore = Mock.log("start.m3u8").count
        TVTest.remote.press(.home)
        TVTest.settle(8)
        app.activate()
        TVTest.settle(15)
        XCTAssertGreaterThan(Mock.log("start.m3u8").count, startsBefore, "returning rebuilds the paused transcode")
        TVTest.capture("01-back-paused", in: self)

        let beforePlay = timelineMark()
        TVTest.remote.press(.playPause)
        XCTAssertTrue(waitForReport(Self.episode, state: "playing", since: beforePlay, timeout: 15), "Play/Pause plays")
        TVTest.settle(10)
        TVTest.capture("02-playing-from-the-pause", in: self)
        let reports = timeline(since: beforePlay).filter { $0.ratingKey == Self.episode }
        let resumeMs = paused - rewindMs
        let trace = reports.map { "\($0.state)@\($0.timeMs)" }
        XCTAssertTrue(reports.allSatisfy { $0.timeMs >= resumeMs - 3_000 }, "playing again starts \(rewindMs) ms behind the pause at \(paused) ms, not at the start: \(trace)")
        XCTAssertTrue(reports.allSatisfy { $0.timeMs <= paused + 15_000 }, "nothing skips ahead of the pause: \(trace)")
        XCTAssertTrue(reports.last.map { $0.state == "playing" && $0.timeMs > resumeMs } ?? false, "the player plays on from there: \(trace)")
    }
}
