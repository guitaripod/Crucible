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
/// - skip mode and autoplay: launch arguments override `skipIntroMode` and `autoplayNextEpisode`.
@MainActor
final class PlayerTests: XCTestCase {
    private static let episode = "4013"
    private static let nextEpisode = "4014"
    private static let movie = "1001"
    private static let endOfItemWait: TimeInterval = 180
    private static let dismissalWait: TimeInterval = 45

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
        XCTAssertTrue(app.otherElements["player.upNext"].waitForExistence(timeout: 40))
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
        let app = launch(playing: Self.episode, arguments: ["-autoplayNextEpisode", "<true/>", "-skipIntroMode", "2"])
        XCTAssertTrue(waitForPlayback(in: app))
        XCTAssertTrue(app.otherElements["player.upNext"].waitForExistence(timeout: 40))
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

    /// Presses Left until the card's leave button has focus, so a press that the busy focus engine swallowed is repeated instead of Select landing on Play Now.
    private func focusLeaveButton(_ leave: XCUIElement) -> Bool {
        for _ in 0..<4 {
            if leave.hasFocus { return true }
            TVTest.remote.press(.left)
            if TVTest.waitForFocus(leave, timeout: 4) { return true }
        }
        return leave.hasFocus
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
    }

    private func timeline(since mark: Int) -> [Report] {
        Mock.log("/:/timeline").dropFirst(mark).compactMap { line in
            guard let components = URLComponents(string: "http://x" + line.dropFirst(4)),
                  let items = components.queryItems,
                  let key = items.first(where: { $0.name == "ratingKey" })?.value,
                  let state = items.first(where: { $0.name == "state" })?.value else { return nil }
            return Report(ratingKey: key, state: state)
        }
    }

    private func timelineMark() -> Int {
        Mock.log("/:/timeline").count
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
