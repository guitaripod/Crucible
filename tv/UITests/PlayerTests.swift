import XCTest

/// Drives the system player through the mock server. Playback starts from the `crucible://play/<id>`
/// link, the same seam Top Shelf uses. States are reached like this:
/// - pre-roll: `CRUCIBLE_PLAYER_HOLD` (DEBUG only) delays the stream resolve so the pre-roll stays up;
/// - resume: the item's progress is written to the mock with a `/:/timeline` call before the link;
/// - Skip Intro: the mock's intro marker is 12 to 58 s, so resuming at 8 s reaches it in about 5 s;
/// - Skip Credits and Up Next: `clip_markers=1` moves the credits to 110 s of the 150 s clip;
/// - failure: `fail_parts` and `fail_transcode` break direct play and its transcode fallback;
/// - skip mode and autoplay: launch arguments override `skipIntroMode` and `autoplayNextEpisode`.
@MainActor
final class PlayerTests: XCTestCase {
    private static let episode = "4013"
    private static let nextEpisode = "4014"
    private static let movie = "1001"

    private nonisolated var mock: URL {
        URL(string: ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"] ?? "http://127.0.0.1:32467")!
    }

    override func setUp() {
        continueAfterFailure = false
        setFlags("clip_markers=0&fail_parts=0&fail_transcode=0&latency_ms=0")
    }

    override func tearDown() {
        setFlags("clip_markers=0&fail_parts=0&fail_transcode=0&latency_ms=0")
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

    func testDismissingTheUpNextCardEndsThePlayer() {
        setFlags("clip_markers=1")
        setProgress(Self.episode, seconds: 104)
        let app = launch(playing: Self.episode, arguments: ["-autoplayNextEpisode", "<false/>", "-skipIntroMode", "2"])
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertTrue(app.otherElements["player.upNext"].waitForExistence(timeout: 40))
        TVTest.remote.press(.left)
        TVTest.settle(1)
        TVTest.capture("01-dismiss-focused", in: self)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20))
        TVTest.settle(1)
        TVTest.capture("02-back-in-app", in: self)
    }

    func testMenuOnTheUpNextCardKeepsTheCreditsPlaying() {
        setFlags("clip_markers=1")
        setProgress(Self.episode, seconds: 104)
        let app = launch(playing: Self.episode, arguments: ["-autoplayNextEpisode", "<false/>", "-skipIntroMode", "2"])
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertTrue(app.otherElements["player.upNext"].waitForExistence(timeout: 40))
        TVTest.remote.press(.menu)
        TVTest.settle(2)
        TVTest.capture("01-after-menu", in: self)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "the player stays up")
    }

    func testAutoplayStartsTheNextEpisodeAfterTheCountdown() {
        setFlags("clip_markers=1")
        setProgress(Self.episode, seconds: 104)
        let app = launch(playing: Self.episode, arguments: ["-autoplayNextEpisode", "<true/>", "-skipIntroMode", "2"])
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

    private func launch(playing ratingKey: String, arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launchArguments += arguments
        app.launchEnvironment["CRUCIBLE_UITEST"] = "1"
        app.launchEnvironment["CRUCIBLE_OPEN_LINK"] = "crucible://play/\(ratingKey)"
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("CRUCIBLE_") && key != "CRUCIBLE_OPEN_LINK" {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    private func waitForPlayback(in app: XCUIApplication) -> Bool {
        app.otherElements["player.view"].waitForExistence(timeout: 60)
    }

    private nonisolated func setFlags(_ query: String) {
        _ = try? Data(contentsOf: URL(string: "\(mock.absoluteString)/mock/flags?\(query)")!)
    }

    private nonisolated func setProgress(_ ratingKey: String, seconds: Int) {
        let ms = seconds * 1000
        let query = "ratingKey=\(ratingKey)&key=/library/metadata/\(ratingKey)&state=stopped&time=\(ms)&duration=2700000"
        _ = try? Data(contentsOf: URL(string: "\(mock.absoluteString)/:/timeline?\(query)")!)
    }
}
