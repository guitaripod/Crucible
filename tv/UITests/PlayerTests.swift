import XCTest

/// Drives the system player through the mock server. Playback starts from the `crucible://play/<id>`
/// link, the same seam Top Shelf uses. States are reached like this:
/// - pre-roll: `CRUCIBLE_PLAYER_HOLD` (DEBUG only) delays the stream resolve so the pre-roll stays up;
/// - a resolve that fails once: `CRUCIBLE_PLAYER_FAIL_RESOLVE_ONCE=<ratingKey>` (DEBUG only) makes that item's first
///   resolve fail with a connection error, so Retry can be tested without racing other requests;
/// - resume: the item's progress is written to the mock with a `/:/timeline` call before the link;
/// - Skip Intro: the mock's intro marker is 12 to 58 s, so resuming at 8 s reaches it in about 5 s;
/// - Skip Credits and Up Next: `clip_markers=1` moves the credits to 110 s of the 150 s clip;
/// - failure: `fail_parts` and `fail_transcode` break direct play and its transcode fallback;
/// - skip mode, outro and autoplay: launch arguments override `skipIntroMode`, `skipOutroMode` and `autoplayNextEpisode`;
/// - a player that loses its place while the app is away: `CRUCIBLE_PLAYER_CLOCK_RESET=1` (DEBUG only) rewinds the player's clock to zero right after the app went to the background;
/// - an Apple TV that sleeps without telling the app: `CRUCIBLE_PLAYER_SLEEP_AT=<seconds>` with `CRUCIBLE_PLAYER_SLEEP_FOR=<seconds>` (DEBUG only) pauses the player once the playhead passes SLEEP_AT, drops the
///   transcode session on the mock (`/mock/reap`) and jumps the session's clock ahead, with no lifecycle notification; the heartbeat has to notice;
/// - a run of episodes nobody watched: `CRUCIBLE_PLAYER_UNATTENDED=<n>` (DEBUG only) starts the player as if `n` episodes had already played with nobody at the remote.
@MainActor
final class PlayerTests: TVTestCase {
    private static let episode = "4013"
    private static let nextEpisode = "4014"
    private static let movie = "1001"
    private static let endOfItemWait: TimeInterval = 180
    private static let dismissalWait: TimeInterval = 45
    /// Direct play (Original quality), whatever an earlier test class left in the simulator's preferences: a transcode of the mock ignores the resume offset, so an item resumed near the end would not end.
    private static let defaultQuality = "0"

    override func setUp() {
        continueAfterFailure = false
        TVTest.configureMock()
        setFlags("clip_markers=0&no_credits=0&fail_parts=0&fail_transcode=0&fail_metadata_once=0&latency_ms=0")
    }

    override func tearDown() {
        setFlags("clip_markers=0&no_credits=0&fail_parts=0&fail_transcode=0&fail_metadata_once=0&latency_ms=0")
    }

    func testMoviePlaysFromPreRollToTransportBarAndBack() {
        setProgress(Self.movie, seconds: 1)
        let app = launch(playing: Self.movie, environment: ["CRUCIBLE_PLAYER_HOLD": "6"])
        let waiting = app.otherElements["player.preroll"].waitForExistence(timeout: 60)
        TVTest.capture("01-preroll", in: self)
        XCTAssertTrue(waiting)

        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(2)
        TVTest.capture("02-playing", in: self)

        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        TVTest.capture("03-transport-bar", in: self)

        TVTest.remote.press(.down)
        TVTest.settle(1.5)
        TVTest.capture("04-info-panel", in: self)

        for _ in 0..<5 where !app.tabBars.firstMatch.exists {
            TVTest.remote.press(.menu)
            TVTest.settle(2)
        }
        TVTest.capture("05-back-in-app", in: self)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "Menu leaves the player and returns to the app")
    }

    func testEpisodeInfoPanelLeadsWithTheShowAndNumber() {
        setProgress(Self.episode, seconds: 1)
        let app = launch(playing: Self.episode)
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(3)
        TVTest.remote.press(.select)
        TVTest.remote.press(.down)
        TVTest.settle(1.5)
        TVTest.capture("01-episode-info-panel", in: self)
    }

    func testScrubbingWithLongPressRight() {
        setProgress(Self.movie, seconds: 1)
        let app = launch(playing: Self.movie)
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(2)
        TVTest.remote.press(.select)
        TVTest.remote.longPress(.right, duration: 2)
        TVTest.settle(1.5)
        TVTest.capture("01-scrubbed-forward", in: self)
    }

    /// A click on the left of the clickpad skips back the distance chosen in Settings (30 s here), not the system's ten seconds.
    func testAClickLeftSkipsBackTheChosenDistance() {
        setProgress(Self.movie, seconds: 100)
        let app = launch(playing: Self.movie, arguments: ["-skipBackSeconds", "<integer>30</integer>"])
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(6)
        let mark = timelineMark()
        TVTest.remote.press(.left)
        TVTest.settle(5)
        let reports = timeline(since: mark).map(\.timeMs)
        XCTAssertTrue(reports.contains { (68_000...84_000).contains($0) }, "the click lands about 30 s back: \(reports)")
        XCTAssertFalse(reports.contains { (92_000...99_000).contains($0) }, "not the system's ten seconds back: \(reports)")
        TVTest.capture("01-skipped-back-30", in: self)
    }

    /// A click on the right skips ahead the distance chosen in Settings (45 s here).
    func testAClickRightSkipsAheadTheChosenDistance() {
        setProgress(Self.movie, seconds: 20)
        let app = launch(playing: Self.movie, arguments: ["-skipForwardSeconds", "<integer>45</integer>"])
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(6)
        let before = currentPositionMs()
        let mark = timelineMark()
        TVTest.remote.press(.right)
        TVTest.settle(5)
        let reports = timeline(since: mark).map(\.timeMs)
        XCTAssertTrue(reports.contains { (before + 40_000...before + 56_000).contains($0) }, "the click lands about 45 s ahead of \(before): \(reports)")
    }

    /// Holding the right of the clickpad, set to jump two minutes, jumps there instead of scanning.
    func testHoldingRightSetToJumpJumpsAhead() {
        setProgress(Self.movie, seconds: 10)
        let app = launch(playing: Self.movie, arguments: ["-holdRightAction", "<integer>120</integer>"])
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(5)
        let mark = timelineMark()
        TVTest.remote.longPress(.right, duration: 1.2)
        TVTest.settle(5)
        let reports = timeline(since: mark).map(\.timeMs)
        XCTAssertTrue(reports.contains { (128_000...148_000).contains($0) }, "the hold jumps about two minutes ahead: \(reports)")
        TVTest.capture("01-held-right-jumped", in: self)
    }

    /// A click back inside a transcode's own stream seeks in place: the server is not asked for a new transcode, so nothing the
    /// viewer chose on the item (such as subtitles off) is reset. It starts past the mock's intro marker (12 to 58 s), where a
    /// Skip Intro action on screen would take the click as focus movement.
    func testAClickBackInsideATranscodeDoesNotRestartIt() {
        setProgress(Self.episode, seconds: 70)
        let app = launch(playing: Self.episode, arguments: ["-streamingQuality", "8000"])
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(16)
        let before = currentPositionMs()
        let startsBefore = transcodeStarts().count
        let mark = timelineMark()
        TVTest.remote.press(.left)
        TVTest.settle(6)
        XCTAssertEqual(transcodeStarts().count, startsBefore, "no new transcode: \(transcodeStarts().dropFirst(startsBefore))")
        let reports = timeline(since: mark).map(\.timeMs)
        XCTAssertTrue(reports.contains { (before - 12_000...before - 2_000).contains($0) }, "the click lands about 10 s back from \(before): \(reports)")
    }

    func testSkipIntroActionAppearsInsideTheMarkerWindowAndSkips() {
        setProgress(Self.episode, seconds: 8)
        let app = launch(playing: Self.episode, arguments: ["-skipIntroMode", "0"])
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(7)
        TVTest.capture("01-skip-intro-action", in: self)

        TVTest.remote.press(.down)
        TVTest.settle(1)
        TVTest.capture("02-skip-intro-focused", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(2)
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        TVTest.capture("03-after-skip-time-near-1-00", in: self)
    }

    func testAutomaticSkipOffersUndo() {
        setProgress(Self.episode, seconds: 8)
        let app = launch(playing: Self.episode, arguments: ["-skipIntroMode", "1"])
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(6)
        TVTest.capture("01-auto-skip-undo-action", in: self)
        TVTest.settle(5)
        TVTest.capture("02-undo-expired", in: self)
    }

    func testUpNextProposalAtTheCreditsAndAcceptingStartsTheNextEpisode() {
        setFlags("clip_markers=1")
        setProgress(Self.episode, seconds: 104)
        let app = launch(playing: Self.episode, arguments: ["-autoplayNextEpisode", "<false/>", "-skipIntroMode", "2"])
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(5)
        TVTest.capture("01-before-credits", in: self)
        TVTest.settle(3)
        TVTest.capture("02-up-next-proposal", in: self)
        TVTest.settle(3)
        TVTest.capture("03-up-next-proposal-later", in: self)

        TVTest.remote.press(.select)
        TVTest.settle(4)
        TVTest.capture("04-next-episode-playing", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        TVTest.capture("05-next-episode-info", in: self)
    }

    func testMenuOnTheUpNextCardKeepsTheCreditsPlaying() {
        setFlags("clip_markers=1")
        setProgress(Self.episode, seconds: 104)
        let app = launch(playing: Self.episode, arguments: ["-autoplayNextEpisode", "<false/>", "-skipIntroMode", "2"])
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertTrue(waitForFocusedUpNextCard(in: app))
        TVTest.remote.press(.menu)
        TVTest.settle(2)
        TVTest.capture("01-after-menu", in: self)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "the player stays up")
    }

    /// Skip Outro off: the credits play without the Up Next card and nothing starts the next episode.
    func testSkipOutroOffLetsTheCreditsPlayWithoutTheCard() {
        setFlags("clip_markers=1")
        setProgress(Self.episode, seconds: 104)
        let app = launch(
            playing: Self.episode,
            arguments: ["-autoplayNextEpisode", "<false/>", "-skipOutroMode", "2", "-skipIntroMode", "2"]
        )
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(12)
        TVTest.capture("01-credits-without-up-next", in: self)
        XCTAssertFalse(app.otherElements["player.upNext"].exists, "Skip Outro off keeps the Up Next card away")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "the credits keep the player up")
    }

    func testAutoplayStartsTheNextEpisodeAfterTheCountdown() {
        setFlags("clip_markers=1")
        setProgress(Self.episode, seconds: 104)
        let app = launch(playing: Self.episode, arguments: ["-autoplayNextEpisode", "<true/>", "-skipOutroMode", "1", "-skipIntroMode", "2"])
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(8)
        TVTest.capture("01-autoplay-proposal", in: self)
        TVTest.settle(14)
        TVTest.capture("02-autoplay-next-episode", in: self)
    }

    func testAudioMenuReResolvesTheStreamForAnotherTrack() {
        setProgress(Self.episode, seconds: 1)
        let app = launch(playing: Self.episode)
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(3)
        TVTest.remote.press(.select)
        TVTest.remote.press(.up)
        for _ in 0..<4 { TVTest.remote.press(.left) }
        TVTest.settle(1)
        TVTest.capture("01-menu-buttons-focused", in: self)

        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        TVTest.capture("02-audio-menu", in: self)

        TVTest.remote.press(.down)
        TVTest.remote.press(.select)
        TVTest.settle(6)
        TVTest.capture("03-after-choosing-another-audio-track", in: self)
    }

    func testFailedPlaybackOffersRetryAndClose() {
        setFlags("fail_parts=1&fail_transcode=1")
        setProgress(Self.episode, seconds: 1)
        let app = launch(playing: Self.episode)
        let alert = app.alerts["Playback Error"]
        XCTAssertTrue(alert.waitForExistence(timeout: 40))
        TVTest.settle(1)
        TVTest.capture("01-playback-error", in: self)
        XCTAssertTrue(alert.buttons["Retry"].exists)
        XCTAssertTrue(alert.buttons["Close"].exists)

        setFlags("fail_parts=0&fail_transcode=0")
        TVTest.remote.press(.select)
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(2)
        TVTest.capture("02-after-retry-playing", in: self)
    }

    func testCloseOnTheErrorAlertReturnsToTheApp() {
        setFlags("fail_parts=1&fail_transcode=1")
        let app = launch(playing: Self.episode)
        let alert = app.alerts["Playback Error"]
        XCTAssertTrue(alert.waitForExistence(timeout: 40))
        TVTest.settle(2)
        TVTest.remote.press(.left)
        TVTest.settle(1)
        TVTest.capture("01-close-focused", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(4)
        TVTest.capture("02-after-close", in: self)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
    }

    func testPlayingAnotherItemWhilePlayingKeepsTheSecondPlayer() {
        setProgress(Self.episode, seconds: 1)
        setProgress(Self.nextEpisode, seconds: 1)
        let mark = timelineMark()
        let app = launch(playing: Self.episode, environment: ["CRUCIBLE_OPEN_LINK_LATER": "12:crucible://play/\(Self.nextEpisode)"])
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertTrue(waitForReport(Self.nextEpisode, state: "playing", since: mark, timeout: 60), "the second link starts playing")
        TVTest.settle(6)
        TVTest.capture("01-second-player-up", in: self)
        XCTAssertTrue(app.otherElements["player.view"].exists, "the second player is still on screen")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        let reports = timeline(since: mark)
        XCTAssertTrue(reports.contains { $0.ratingKey == Self.episode && $0.state == "stopped" }, "the first session was stopped")
        XCTAssertFalse(reports.contains { $0.ratingKey == Self.nextEpisode && $0.state == "stopped" }, "the second session was not")
    }

    func testAnItemLinkWhilePlayingEndsThePlaybackCleanly() {
        setProgress(Self.episode, seconds: 1)
        let mark = timelineMark()
        let app = launch(playing: Self.episode, environment: ["CRUCIBLE_OPEN_LINK_LATER": "12:crucible://item/4009?type=episode"])
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60), "the link leaves the player")
        XCTAssertTrue(waitForReport(Self.episode, state: "stopped", since: mark, timeout: 20), "the session reported stopped")
        TVTest.settle(3)
        TVTest.capture("01-detail-after-link", in: self)
        let afterStop = timeline(since: mark)
        let stoppedAt = afterStop.lastIndex { $0.ratingKey == Self.episode && $0.state == "stopped" } ?? 0
        TVTest.settle(14)
        let later = timeline(since: mark).dropFirst(stoppedAt + 1)
        XCTAssertFalse(later.contains { $0.ratingKey == Self.episode && $0.state == "playing" }, "nothing keeps reporting after the stop")
    }

    func testRetryAfterAFailedFirstResolveShowsThePlayer() {
        setProgress(Self.episode, seconds: 1)
        let app = launch(
            playing: Self.episode,
            environment: ["CRUCIBLE_PLAYER_HOLD": "4", "CRUCIBLE_PLAYER_FAIL_RESOLVE_ONCE": Self.episode]
        )
        XCTAssertTrue(app.otherElements["player.preroll"].waitForExistence(timeout: 60))
        let alert = app.alerts["Playback Error"]
        XCTAssertTrue(alert.waitForExistence(timeout: 30))
        TVTest.settle(2)
        TVTest.capture("01-resolve-failed", in: self)
        TVTest.remote.press(.select)
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(2)
        XCTAssertFalse(app.otherElements["player.preroll"].exists, "no pre-roll is left behind the player")
        TVTest.capture("02-player-after-retry", in: self)
    }

    func testRetryAfterAFailedNextEpisodeResolveShowsTheNextEpisode() {
        setFlags("clip_markers=1")
        setProgress(Self.episode, seconds: 104)
        setProgress(Self.nextEpisode, seconds: 1)
        let mark = timelineMark()
        let app = launch(
            playing: Self.episode,
            arguments: ["-autoplayNextEpisode", "<false/>", "-skipIntroMode", "2"],
            environment: ["CRUCIBLE_PLAYER_FAIL_RESOLVE_ONCE": Self.nextEpisode]
        )
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertTrue(waitForFocusedUpNextCard(in: app))
        TVTest.remote.press(.select)
        let alert = app.alerts["Playback Error"]
        XCTAssertTrue(alert.waitForExistence(timeout: 30))
        TVTest.settle(2)
        TVTest.capture("01-next-resolve-failed", in: self)
        TVTest.remote.press(.select)
        XCTAssertTrue(waitForReport(Self.nextEpisode, state: "playing", since: mark, timeout: 40))
        TVTest.settle(3)
        XCTAssertFalse(app.otherElements["player.preroll"].exists, "no stale pre-roll over the next episode")
        TVTest.capture("02-next-episode-after-retry", in: self)
    }

    func testMenuReturnsQuicklyEvenWhenTheServerIsSlow() {
        setProgress(Self.movie, seconds: 1)
        let app = launch(playing: Self.movie)
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(9)
        setFlags("latency_ms=9000")
        let started = Date()
        TVTest.remote.press(.menu)
        let back = app.otherElements["player.view"].waitForNonExistence(timeout: 12) && app.tabBars.firstMatch.exists
        let elapsed = Date().timeIntervalSince(started)
        TVTest.capture("01-back-while-the-server-is-slow", in: self)
        XCTAssertTrue(back)
        XCTAssertLessThan(elapsed, 7, "Menu does not wait for the slow server (took \(elapsed) s)")
    }

    func testWatchCreditsDefersTheCardAndItReturnsAtTheEndAsClose() {
        setFlags("clip_markers=1")
        setProgress(Self.episode, seconds: 104)
        let app = launch(playing: Self.episode, arguments: ["-autoplayNextEpisode", "<false/>", "-skipIntroMode", "2"])
        XCTAssertTrue(waitForPlayback(in: app))
        let leave = app.buttons["player.upNext.leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 40))
        XCTAssertEqual(leave.label, "Watch Credits")
        XCTAssertTrue(focusLeaveButton(leave), "Watch Credits can be focused")
        TVTest.capture("01-watch-credits-focused", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(2)
        XCTAssertFalse(app.otherElements["player.upNext"].exists, "the card is gone")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "the credits keep playing")
        TVTest.capture("02-credits-playing", in: self)

        XCTAssertTrue(app.otherElements["player.upNext"].waitForExistence(timeout: Self.endOfItemWait), "the card returns when the item ends")
        TVTest.settle(2)
        XCTAssertEqual(app.buttons["player.upNext.leave"].label, "Close", "at the end leaving the card closes the player")
        TVTest.capture("03-card-at-the-end", in: self)
        XCTAssertTrue(focusLeaveButton(app.buttons["player.upNext.leave"]), "Close can be focused")
        TVTest.remote.press(.select)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: Self.dismissalWait))
    }

    func testWatchCreditsThenTheEndPlaysTheNextEpisodeWithAutoplay() {
        setFlags("clip_markers=1")
        setProgress(Self.episode, seconds: 104)
        setProgress(Self.nextEpisode, seconds: 1)
        let mark = timelineMark()
        let app = launch(playing: Self.episode, arguments: ["-autoplayNextEpisode", "<true/>", "-skipOutroMode", "1", "-skipIntroMode", "2"])
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertTrue(waitForFocusedUpNextCard(in: app))
        TVTest.remote.press(.menu)
        TVTest.settle(2)
        XCTAssertFalse(app.otherElements["player.upNext"].exists)
        XCTAssertTrue(waitForReport(Self.nextEpisode, state: "playing", since: mark, timeout: Self.endOfItemWait), "the next episode starts when the item ends")
        TVTest.settle(3)
        TVTest.capture("01-next-episode-after-the-end", in: self)
        XCTAssertTrue(app.otherElements["player.view"].exists)
    }

    func testWithoutCreditsTheCardOffersCloseAndEndsThePlayer() {
        setFlags("no_credits=1")
        setProgress(Self.episode, seconds: 144)
        let app = launch(playing: Self.episode, arguments: ["-autoplayNextEpisode", "<false/>", "-skipIntroMode", "2"])
        XCTAssertTrue(waitForPlayback(in: app))
        let leave = app.buttons["player.upNext.leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 40))
        XCTAssertEqual(leave.label, "Close")
        XCTAssertTrue(focusLeaveButton(leave), "Close can be focused")
        TVTest.capture("01-close-focused", in: self)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: Self.dismissalWait))
    }

    func testFinishingTheFirstVideoOffersProToAFreeViewerOnce() {
        setFlags("no_credits=1")
        setProgress(Self.episode, seconds: 144)
        let app = launch(
            playing: Self.episode,
            arguments: ["-autoplayNextEpisode", "<false/>", "-skipIntroMode", "2"],
            environment: ["CRUCIBLE_FRESH": "1", "CRUCIBLE_PRO": "free"]
        )
        XCTAssertTrue(waitForPlayback(in: app))
        let leave = app.buttons["player.upNext.leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 40))
        XCTAssertTrue(focusLeaveButton(leave), "Close can be focused")
        TVTest.remote.press(.select)
        let offer = app.alerts["Go further with Crucible Pro"]
        XCTAssertTrue(offer.waitForExistence(timeout: Self.dismissalWait), "the first finished video offers Pro")
        TVTest.capture("01-pro-offer-after-the-first-video", in: self)
        XCTAssertTrue(offer.buttons["Not Now"].exists)
    }

    func testBackgroundingReportsPausedAndAPausedTranscodeRestartsOnReturn() {
        setProgress(Self.episode, seconds: 20)
        let mark = timelineMark()
        let app = launch(playing: Self.episode, arguments: ["-streamingQuality", "8000"])
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(6)
        let startsBefore = Mock.log("start.m3u8").count
        XCTAssertGreaterThan(startsBefore, 0, "the stream is a transcode")
        TVTest.remote.press(.home)
        XCTAssertTrue(waitForReport(Self.episode, state: "paused", since: mark, timeout: 20), "leaving the app reports paused")
        app.activate()
        TVTest.settle(6)
        XCTAssertGreaterThan(Mock.log("start.m3u8").count, startsBefore, "returning restarts the paused transcode")
        XCTAssertTrue(app.otherElements["player.view"].exists)
        TVTest.capture("01-back-from-the-home-screen", in: self)
    }

    func testReturningFromTheHomeScreenKeepsTheTranscodePositionWhenThePlayerClockLostItsPlace() {
        assertReturnKeepsThePosition(quality: "8000", restartsTheStream: true)
    }

    func testReturningFromTheHomeScreenKeepsTheDirectPlayPositionWhenThePlayerClockLostItsPlace() {
        assertReturnKeepsThePosition(quality: Self.defaultQuality, restartsTheStream: false)
    }

    /// Plays from 20 s, goes to the Home screen with the player's own clock reset to zero (`CRUCIBLE_PLAYER_CLOCK_RESET`, DEBUG only), returns and
    /// checks that no timeline report falls back towards the start, that a transcode is rebuilt at the position and that the player is still up.
    private func assertReturnKeepsThePosition(quality: String, restartsTheStream: Bool) {
        let resume = 20
        setProgress(Self.episode, seconds: resume)
        let app = launch(
            playing: Self.episode,
            arguments: ["-streamingQuality", quality],
            environment: ["CRUCIBLE_PLAYER_CLOCK_RESET": "1"]
        )
        XCTAssertTrue(waitForPlayback(in: app))
        TVTest.settle(8)
        let startsBefore = Mock.log("start.m3u8").count
        let mark = timelineMark()
        TVTest.remote.press(.home)
        XCTAssertTrue(waitForReport(Self.episode, state: "paused", since: mark, timeout: 20), "leaving the app reports paused")
        TVTest.settle(5)
        app.activate()
        TVTest.settle(12)
        let reports = timeline(since: mark)
        XCTAssertFalse(reports.isEmpty)
        let floor = (resume + 4) * 1000
        XCTAssertTrue(reports.allSatisfy { $0.timeMs >= floor }, "no report goes back towards the start: \(reports.map(\.timeMs))")
        if restartsTheStream {
            let restarts = Mock.log("start.m3u8").dropFirst(startsBefore)
            XCTAssertTrue(restarts.contains { Self.offset(in: $0) >= resume + 4 }, "the transcode restarts at the position: \(restarts)")
        }
        XCTAssertTrue(app.otherElements["player.view"].exists)
        TVTest.capture("01-back-at-the-same-place", in: self)
    }

    /// A transcode (8000 kbps) that the Apple TV's sleep froze without a word: after two hours away the heartbeat rebuilds it under a new server
    /// session fifteen seconds behind where it stopped, and the player stays paused instead of playing into an empty room.
    func testASleepNobodyAnnouncedRebuildsTheTranscodeUnderANewSessionBehindThePosition() {
        setProgress(Self.episode, seconds: 20)
        let startsBefore = transcodeStarts().count
        let mark = timelineMark()
        let app = launch(
            playing: Self.episode,
            arguments: ["-streamingQuality", "8000", "-rewindAfterBreak", "<true/>"],
            environment: sleepEnvironment(at: 30, for: 7200)
        )
        XCTAssertTrue(waitForPlayback(in: app))
        let rebuild = waitForRebuild(after: startsBefore, timeout: 90)
        TVTest.capture("01-after-the-sleep", in: self)
        let first = transcodeStarts().dropFirst(startsBefore).first.map(Self.session(in:))
        XCTAssertNotNil(rebuild, "the heartbeat rebuilds the transcode: \(transcodeStarts().dropFirst(startsBefore))")
        guard let rebuild else { return }
        XCTAssertNotEqual(rebuild.session, first, "the rebuild runs under a new server session")
        XCTAssertTrue((14...16).contains(rebuild.offset), "the rebuild starts 15 s behind the position of 30 s: offset \(rebuild.offset)")

        let settled = timelineMark()
        XCTAssertFalse(app.otherElements["player.upNext"].waitForExistence(timeout: 20), "the rebuild is not taken for the end of the item")
        XCTAssertTrue(app.otherElements["player.view"].exists, "the player is still up")
        TVTest.settle(15)
        let last = timeline(since: mark).last
        XCTAssertEqual(last?.state, "paused", "the last report says paused: \(timeline(since: mark).map { "\($0.state)@\($0.timeMs)" })")
        XCTAssertTrue(last.map { abs($0.timeMs - rebuild.offset * 1000) <= 1000 } ?? false, "the last report is at the rebuild's start")
        let afterSleep = reportsAfterSleep(since: mark, at: 30)
        XCTAssertFalse(afterSleep.isEmpty)
        XCTAssertTrue(afterSleep.allSatisfy { $0.timeMs >= 14000 }, "no report goes back towards the start: \(afterSleep.map(\.timeMs))")
        let later = timeline(since: settled)
        XCTAssertTrue(later.allSatisfy { $0.timeMs <= (rebuild.offset + 3) * 1000 }, "nothing plays on after the rebuild: \(later.map { "\($0.state)@\($0.timeMs)" })")
        XCTAssertTrue(later.allSatisfy { $0.state == "paused" }, "the player stays paused: \(later.map(\.state))")
        XCTAssertTrue(app.otherElements["player.view"].exists)
        TVTest.capture("02-paused-behind-the-position", in: self)
    }

    /// The same sleep on a direct-play file: nothing is rebuilt, the player seeks back to where the rewind puts it and no report falls towards the start.
    func testASleepNobodyAnnouncedOnDirectPlaySeeksBehindThePosition() {
        setProgress(Self.episode, seconds: 20)
        let mark = timelineMark()
        let app = launch(
            playing: Self.episode,
            arguments: ["-rewindAfterBreak", "<true/>"],
            environment: sleepEnvironment(at: 30, for: 7200)
        )
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertTrue(waitForReport(pastMs: 30000, since: mark, timeout: 90), "the playhead reaches the sleep")
        TVTest.settle(15)
        let afterSleep = reportsAfterSleep(since: mark, at: 30)
        XCTAssertFalse(afterSleep.isEmpty)
        XCTAssertTrue(afterSleep.allSatisfy { $0.timeMs >= 14000 }, "no report goes back towards the start: \(afterSleep.map(\.timeMs))")
        let settled = timeline(since: mark).last
        XCTAssertNotNil(settled)
        XCTAssertTrue((14000...17000).contains(settled?.timeMs ?? 0), "the player settles about 15 s behind the position: \(afterSleep.map { "\($0.state)@\($0.timeMs)" })")
        XCTAssertTrue(app.otherElements["player.view"].exists, "the player is still up")
        TVTest.capture("01-direct-play-after-the-sleep", in: self)
    }

    /// Two hours away with "Rewind After a Break" off: the transcode is rebuilt exactly where it stopped, not the fifteen seconds behind it the setting would give.
    func testALongAbsenceWithRewindOffComesBackExactly() {
        setProgress(Self.episode, seconds: 20)
        let startsBefore = transcodeStarts().count
        let app = launch(
            playing: Self.episode,
            arguments: ["-streamingQuality", "8000", "-rewindAfterBreak", "<false/>"],
            environment: sleepEnvironment(at: 30, for: 7200)
        )
        XCTAssertTrue(waitForPlayback(in: app))
        let rebuild = waitForRebuild(after: startsBefore, timeout: 90)
        TVTest.settle(4)
        TVTest.capture("01-back-after-two-hours", in: self)
        XCTAssertNotNil(rebuild, "the heartbeat rebuilds the transcode: \(transcodeStarts().dropFirst(startsBefore))")
        guard let rebuild else { return }
        XCTAssertTrue((29...31).contains(rebuild.offset), "the rebuild starts at the position of 30 s: offset \(rebuild.offset)")
        XCTAssertTrue(app.otherElements["player.view"].exists)
    }

    /// Three unattended episodes in a row and "Still watching?" at three: the card asks instead of counting down, and the next episode starts only when the viewer says so.
    func testStillWatchingAsksInsteadOfCountingDown() {
        setFlags("clip_markers=1")
        setProgress(Self.episode, seconds: 104)
        setProgress(Self.nextEpisode, seconds: 1)
        let mark = timelineMark()
        let app = launch(
            playing: Self.episode,
            arguments: ["-autoplayNextEpisode", "<true/>", "-skipOutroMode", "1", "-skipIntroMode", "2", "-stillWatchingAfterEpisodes", "3"],
            environment: ["CRUCIBLE_PLAYER_UNATTENDED": "3"]
        )
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertTrue(waitForFocusedUpNextCard(in: app))
        TVTest.capture("01-still-watching-card", in: self)
        XCTAssertTrue(app.staticTexts["STILL WATCHING?"].exists, "the eyebrow asks")
        XCTAssertFalse(app.staticTexts["UP NEXT"].exists)
        let play = app.buttons["player.upNext.play"]
        XCTAssertEqual(play.label, "Keep Watching")
        XCTAssertTrue(play.hasFocus)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Playing in'")).firstMatch.exists, "there is no countdown")

        TVTest.settle(15)
        TVTest.capture("02-still-asking-after-15-s", in: self)
        XCTAssertTrue(app.otherElements["player.upNext"].exists, "the card waits for the viewer")
        XCTAssertTrue(app.staticTexts["STILL WATCHING?"].exists)
        let waiting = timeline(since: mark)
        XCTAssertTrue(waiting.contains { $0.ratingKey == Self.episode }, "the episode keeps playing")
        XCTAssertFalse(waiting.contains { $0.ratingKey == Self.nextEpisode && $0.state == "playing" }, "the next episode does not start by itself: \(waiting.map { "\($0.ratingKey)/\($0.state)" })")

        TVTest.remote.press(.select)
        XCTAssertTrue(waitForReport(Self.nextEpisode, state: "playing", since: mark, timeout: 40), "Keep Watching starts the next episode")
        TVTest.settle(3)
        TVTest.capture("03-next-episode-after-keep-watching", in: self)
        XCTAssertTrue(app.otherElements["player.view"].exists)
    }

    /// One episode short of the limit nobody is asked: the card says "UP NEXT", counts down and the next episode starts by itself.
    func testWithoutTheRunTheCardStillCountsDown() {
        setFlags("clip_markers=1")
        setProgress(Self.episode, seconds: 104)
        setProgress(Self.nextEpisode, seconds: 1)
        let mark = timelineMark()
        let app = launch(
            playing: Self.episode,
            arguments: ["-autoplayNextEpisode", "<true/>", "-skipOutroMode", "1", "-skipIntroMode", "2", "-stillWatchingAfterEpisodes", "3"],
            environment: ["CRUCIBLE_PLAYER_UNATTENDED": "2"]
        )
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertTrue(app.otherElements["player.upNext"].waitForExistence(timeout: 40))
        TVTest.capture("01-up-next-counting-down", in: self)
        XCTAssertTrue(app.staticTexts["UP NEXT"].exists, "the eyebrow does not ask")
        XCTAssertFalse(app.staticTexts["STILL WATCHING?"].exists)
        XCTAssertEqual(app.buttons["player.upNext.play"].label, "Play Now")
        XCTAssertTrue(waitForReport(Self.nextEpisode, state: "playing", since: mark, timeout: 40), "the countdown starts the next episode")
        TVTest.settle(3)
        TVTest.capture("02-next-episode-after-the-countdown", in: self)
        XCTAssertTrue(app.otherElements["player.view"].exists)
    }

    /// A transcode that stops at the end of the mock's 150 s clip long before the credits is not the end of the episode: it is rebuilt where it ended, and Up Next stays away.
    func testATranscodeThatEndsBeforeTheCreditsIsRebuiltNotFollowedByUpNext() {
        setProgress(Self.episode, seconds: 20)
        let startsBefore = transcodeStarts().count
        let app = launch(playing: Self.episode, arguments: ["-streamingQuality", "8000", "-autoplayNextEpisode", "<true/>"])
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertGreaterThan(transcodeStarts().count, startsBefore, "the stream is a transcode")
        let rebuild = waitForRebuild(after: startsBefore, minimumOffset: 160, timeout: Self.endOfItemWait)
        TVTest.capture("01-rebuilt-after-the-clip-ended", in: self)
        XCTAssertNotNil(rebuild, "the transcode is rebuilt after the clip ends: \(transcodeStarts().dropFirst(startsBefore))")
        XCTAssertFalse(app.otherElements["player.upNext"].waitForExistence(timeout: 10), "an early end does not propose the next episode")
        XCTAssertTrue(app.otherElements["player.view"].exists)
    }

    /// The transcode starts the mock has logged; the log queries that look for them are in the log too and are left out.
    private func transcodeStarts() -> [String] {
        Mock.log("start.m3u8").filter { $0.hasPrefix("GET /video/") }
    }

    private func sleepEnvironment(at seconds: Int, for length: Int) -> [String: String] {
        ["CRUCIBLE_PLAYER_SLEEP_AT": "\(seconds)", "CRUCIBLE_PLAYER_SLEEP_FOR": "\(length)"]
    }

    /// Waits for a transcode start beyond the first one that a rebuild logged since `count` log lines, as `(session, offset)`; with `minimumOffset` only a start at or past it counts.
    private func waitForRebuild(after count: Int, minimumOffset: Int = 0, timeout: TimeInterval) -> (session: String, offset: Int)? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let starts = transcodeStarts().dropFirst(count)
            if let first = starts.first,
               let rebuild = starts.dropFirst().first(where: { Self.offset(in: $0) >= minimumOffset && Self.session(in: $0) != Self.session(in: first) }) {
                return (Self.session(in: rebuild) ?? "", Self.offset(in: rebuild))
            }
            TVTest.settle(1)
        }
        return nil
    }

    /// The reports from the first one at or past `seconds` (the moment the simulated sleep started) on.
    private func reportsAfterSleep(since mark: Int, at seconds: Int) -> [Report] {
        let reports = timeline(since: mark)
        guard let start = reports.firstIndex(where: { $0.timeMs >= seconds * 1000 }) else { return [] }
        return Array(reports[start...])
    }

    private static func offset(in line: String) -> Int {
        query("offset", in: line).flatMap(Int.init) ?? 0
    }

    private static func session(in line: String) -> String? {
        query("session", in: line)
    }

    private static func query(_ name: String, in line: String) -> String? {
        URLComponents(string: "http://x" + line.dropFirst(4))?.queryItems?.first { $0.name == name }?.value
    }

    private func launch(playing ratingKey: String, arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launchArguments += arguments
        if !arguments.contains("-streamingQuality") {
            app.launchArguments += ["-streamingQuality", Self.defaultQuality]
        }
        app.launchEnvironment["CRUCIBLE_UITEST"] = "1"
        app.launchEnvironment["CRUCIBLE_OPEN_LINK"] = "crucible://play/\(ratingKey)"
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("CRUCIBLE_") && key != "CRUCIBLE_OPEN_LINK" {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    /// Presses Left until the card's leave button has focus, so a press that the busy focus engine swallowed is repeated instead of Select landing on Play Now.
    private func focusLeaveButton(_ leave: XCUIElement) -> Bool {
        for _ in 0..<4 {
            if leave.hasFocus { return true }
            TVTest.remote.press(.left)
            if TVTest.waitForFocus(leave, timeout: 4) { return true }
        }
        return leave.hasFocus
    }

    /// Waits for the Up Next card and for focus to settle on its Play Now button. The card shows up in the accessibility tree while it is still sliding in, about half a second before the focus engine moves focus onto it; a press sent in that gap goes to the player underneath and is lost, which tvOS 27 exposes because it lists the card a little earlier than tvOS 26 did.
    private func waitForFocusedUpNextCard(in app: XCUIApplication, timeout: TimeInterval = 40) -> Bool {
        guard app.otherElements["player.upNext"].waitForExistence(timeout: timeout) else { return false }
        return TVTest.waitForFocus(app.buttons["player.upNext.play"])
    }

    private func waitForPlayback(in app: XCUIApplication) -> Bool {
        app.otherElements["player.view"].waitForExistence(timeout: 60)
    }

    private nonisolated func setFlags(_ query: String) {
        Mock.get("/mock/flags?\(query)")
    }

    private nonisolated func setProgress(_ ratingKey: String, seconds: Int) {
        let ms = seconds * 1000
        Mock.get("/:/timeline?ratingKey=\(ratingKey)&key=/library/metadata/\(ratingKey)&state=stopped&time=\(ms)&duration=2700000")
    }

    private struct Report {
        let ratingKey: String
        let state: String
        let timeMs: Int
    }

    private func timeline(since mark: Int) -> [Report] {
        Mock.log("/:/timeline").dropFirst(mark).compactMap { line in
            guard let components = URLComponents(string: "http://x" + line.dropFirst(4)),
                  let items = components.queryItems,
                  let key = items.first(where: { $0.name == "ratingKey" })?.value,
                  let state = items.first(where: { $0.name == "state" })?.value,
                  let timeMs = items.first(where: { $0.name == "time" })?.value.flatMap(Int.init) else { return nil }
            return Report(ratingKey: key, state: state, timeMs: timeMs)
        }
    }

    /// The position of the last timeline report, which the player sends at least every ten seconds while it plays.
    private func currentPositionMs() -> Int {
        let mark = timelineMark()
        _ = waitForReport(pastMs: 0, since: mark, timeout: 12)
        return timeline(since: 0).last?.timeMs ?? 0
    }

    private func timelineMark() -> Int {
        Mock.log("/:/timeline").count
    }

    private func waitForReport(pastMs: Int, since mark: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if timeline(since: mark).contains(where: { $0.timeMs >= pastMs }) { return true }
            TVTest.settle(1)
        }
        return false
    }

    private func waitForReport(_ ratingKey: String, state: String, since mark: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if timeline(since: mark).contains(where: { $0.ratingKey == ratingKey && $0.state == state }) { return true }
            TVTest.settle(1)
        }
        return false
    }
}

/// The mock server's control surface, called without blocking on a synchronous URL load (which the
/// system flags as a runtime issue when it happens on the main thread).
private enum Mock {
    private final class Box: @unchecked Sendable {
        var data: Data?
    }

    static var base: String {
        ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"] ?? "http://127.0.0.1:32467"
    }

    @discardableResult
    static func get(_ path: String) -> Data? {
        guard let url = URL(string: base + path) else { return nil }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { data, _, _ in
            box.data = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        return box.data
    }

    static func log(_ needle: String) -> [String] {
        let encoded = needle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? needle
        guard let data = get("/mock/log?q=\(encoded)"),
              let lines = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return lines
    }
}
