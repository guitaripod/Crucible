import XCTest

/// The player's sleep timer on Apple TV, through the mock server. `CRUCIBLE_PLAYER_SLEEP_TIMER=<seconds>` (DEBUG only) starts the first
/// item with a timed sleep timer that runs out that many seconds later, and `CRUCIBLE_PLAYER_SLEEP_TIMER=end` with one that stops at
/// the end of the item; the other states are reached as `PlayerTests` describes. When a timer ends the player closes, since tvOS lets
/// only Apple's software put the Apple TV to sleep: the box is left idle for its own Sleep After setting.
@MainActor
final class SleepTimerTests: PlayerTestCase {
    /// A timed sleep timer that runs out fades the sound, pauses and closes the player, so the stream stops and the Apple TV is left
    /// idle for its own Sleep After setting; the server hears that playback stopped.
    func testATimedSleepTimerClosesThePlayerWhenItRunsOut() {
        setProgress(Self.movie, seconds: 20)
        let mark = timelineMark()
        let app = launch(playing: Self.movie, environment: ["CRUCIBLE_PLAYER_SLEEP_TIMER": "15"])
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15 + Self.dismissalWait), "the sleep timer closed the player")
        XCTAssertTrue(waitForReport(Self.movie, state: "stopped", since: mark, timeout: 20), "the server hears that playback stopped")
        TVTest.capture("01-closed-by-the-sleep-timer", in: self)
    }

    /// A timed sleep timer that runs out while the Up Next card counts down: the countdown never starts the next episode, and the
    /// player closes. The card comes about eight seconds in and counts for fifteen, so the timer runs out halfway through.
    func testATimedSleepTimerRunningOutDuringTheUpNextCountdownStartsNothing() {
        setFlags("clip_markers=1")
        setProgress(Self.episode, seconds: 104)
        setProgress(Self.nextEpisode, seconds: 1)
        let mark = timelineMark()
        let app = launch(
            playing: Self.episode,
            arguments: ["-autoplayNextEpisode", "<true/>", "-skipOutroMode", "0", "-skipIntroMode", "2", "-upNext.countdown", "15"],
            environment: ["CRUCIBLE_PLAYER_SLEEP_TIMER": "16"]
        )
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertTrue(waitForFocusedUpNextCard(in: app), "the credits bring the Up Next card before the timer runs out")
        XCTAssertTrue(app.staticTexts.matching(Self.countingDown).firstMatch.exists, "the card counts down until the timer runs out")
        TVTest.capture("00-counting-down", in: self)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 16 + Self.dismissalWait), "the sleep timer closed the player")
        TVTest.settle(12)
        XCTAssertFalse(hasPlayed(Self.nextEpisode, since: mark), "the countdown started the next episode after the sleep timer ran out")
        TVTest.capture("01-closed-with-nothing-next", in: self)
    }

    /// End of Episode with Autoplay on: the card at the credits waits instead of counting down, and when the episode ends the
    /// player closes; the next episode never starts and no Pro note waits on the screen for someone asleep.
    func testEndOfEpisodeSleepTimerStopsAtTheEndInsteadOfPlayingTheNextEpisode() {
        setFlags("clip_markers=1")
        setProgress(Self.episode, seconds: 104)
        setProgress(Self.nextEpisode, seconds: 1)
        let mark = timelineMark()
        let app = launch(
            playing: Self.episode,
            arguments: ["-autoplayNextEpisode", "<true/>", "-skipOutroMode", "0", "-skipIntroMode", "2", "-upNext.countdown", "5"],
            environment: ["CRUCIBLE_PLAYER_SLEEP_TIMER": "end", "CRUCIBLE_FRESH": "1", "CRUCIBLE_PRO": "free"]
        )
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertTrue(waitForFocusedUpNextCard(in: app), "the credits bring the Up Next card")
        XCTAssertFalse(app.staticTexts.matching(Self.countingDown).firstMatch.exists, "the card counts down")
        TVTest.settle(7)
        TVTest.capture("01-card-waits-at-the-credits", in: self)
        XCTAssertFalse(app.staticTexts.matching(Self.countingDown).firstMatch.exists, "the card counts down")
        XCTAssertFalse(hasPlayed(Self.nextEpisode, since: mark), "the next episode started at the credits")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: Self.endOfItemWait), "the end of the episode closed the player")
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 6), "a Pro note waits for someone asleep")
        XCTAssertFalse(hasPlayed(Self.nextEpisode, since: mark), "the next episode started at the end")
        TVTest.capture("02-closed-at-the-end", in: self)
    }

    /// A timed sleep timer counts over a pause too: running out while the viewer has paused closes the player.
    func testATimedSleepTimerRunningOutDuringAPauseClosesThePlayer() {
        setProgress(Self.movie, seconds: 20)
        let mark = timelineMark()
        let app = launch(playing: Self.movie, environment: ["CRUCIBLE_PLAYER_SLEEP_TIMER": "20"])
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(4)
        TVTest.remote.press(.playPause)
        XCTAssertTrue(waitForReport(Self.movie, state: "paused", since: mark, timeout: 15), "the pause reached the server")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "the pause kept the player up")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20 + Self.dismissalWait), "the sleep timer closed the paused player")
        XCTAssertTrue(waitForReport(Self.movie, state: "stopped", since: mark, timeout: 20), "the server hears that playback stopped")
    }

    /// A timed sleep timer that runs out while the titles after a movie are up closes them and the player.
    func testATimedSleepTimerRunningOutAfterAMovieClosesTheTitles() {
        setProgress(Self.movie, seconds: 140)
        let app = launch(playing: Self.movie, environment: ["CRUCIBLE_PLAYER_SLEEP_TIMER": "30"])
        XCTAssertTrue(waitForPlayback(in: app))
        let postPlay = app.otherElements["postPlay"]
        XCTAssertTrue(postPlay.waitForExistence(timeout: 30), "the end of the movie offered titles before the timer ran out")
        TVTest.capture("01-titles-before-the-timer-runs-out", in: self)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30 + Self.dismissalWait), "the sleep timer closed the titles and the player")
        XCTAssertFalse(postPlay.exists)
    }

    /// The same without a credits marker: the card that comes at the end does not count down, and the player closes.
    func testEndOfEpisodeSleepTimerWithoutCreditsClosesThePlayerAtTheEnd() {
        setFlags("no_credits=1")
        setProgress(Self.episode, seconds: 144)
        setProgress(Self.nextEpisode, seconds: 1)
        let mark = timelineMark()
        let app = launch(
            playing: Self.episode,
            arguments: ["-autoplayNextEpisode", "<true/>", "-skipOutroMode", "0", "-skipIntroMode", "2", "-upNext.countdown", "5"],
            environment: ["CRUCIBLE_PLAYER_SLEEP_TIMER": "end"]
        )
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: Self.endOfItemWait), "the end of the episode closed the player")
        TVTest.settle(10)
        XCTAssertFalse(hasPlayed(Self.nextEpisode, since: mark), "the next episode started at the end")
        TVTest.capture("01-closed-at-the-end-without-credits", in: self)
    }
}
