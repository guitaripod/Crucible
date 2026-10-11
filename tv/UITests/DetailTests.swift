import XCTest
import UIKit

@MainActor
final class DetailTests: XCTestCase {
    private static let halcyon = "1001"
    private static let deepField = "1002"
    private static let saltRoadEpisode = "4012"
    private static let saltRoad = "2001"

    override func setUp() {
        continueAfterFailure = false
        Self.callMock("/mock/detail-reset")
    }

    func testMovieDetailDark() {
        let app = openDetail(Self.halcyon, type: "movie", style: "dark")
        capture("01-movie-primary-focused")
        XCTAssertEqual(app.buttons["detail.action.primary"].label, "Play Halcyon")

        XCTAssertFalse(app.buttons["detail.synopsis.more"].isHittable, "a short synopsis needs no More")
        step(app, .down, until: "detail.cast.")
        capture("04-cast-focused")
        step(app, .down, until: "detail.related.")
        capture("05-related-focused")
        step(app, .down, until: "detail.information")
        TVTest.settle(0.8)
        capture("06-information-focused")

        step(app, .up, until: "detail.related.")
        step(app, .up, until: "detail.cast.")
        step(app, .up, until: "detail.action.")
        TVTest.settle(0.8)
        capture("07-back-at-top")
    }

    func testMoreOpensTheFullSynopsis() {
        let app = openDetail("9407", type: "movie", style: "dark")
        capture("01-long-synopsis-truncated")
        TVTest.remote.press(.up)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.synopsis.more"))
        capture("02-more-focused")
        TVTest.remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["detail.synopsis.close"].waitForExistence(timeout: 5))
        TVTest.settle(0.8)
        capture("03-more-modal")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.synopsis.close"))
        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.synopsis.more"))
        TVTest.remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["detail.synopsis.close"].waitForExistence(timeout: 5))
        TVTest.remote.press(.select)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.synopsis.more"), "Close must return focus to More")
        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.primary"))
    }

    func testPlayAndMarkWatched() {
        let app = openDetail(Self.halcyon, type: "movie", style: "dark", spy: true)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.alerts["Play \(Self.halcyon)"].waitForExistence(timeout: 5))
        let message = alertMessage(app)
        XCTAssertTrue(message.contains("resume=0"), message)
        XCTAssertTrue(message.contains("audio=10012"), message)
        XCTAssertTrue(message.contains("subtitle=-"), message)
        capture("01-play-request")
        TVTest.remote.press(.select)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.primary"))

        TVTest.remote.press(.right)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.watched"))
        XCTAssertEqual(app.buttons["detail.action.watched"].label, "Mark Watched")
        TVTest.remote.press(.select)
        waitForLabel(app.buttons["detail.action.watched"], "Mark Unwatched")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.watched"), "focus must stay on the toggle")
        TVTest.settle(0.8)
        capture("02-marked-watched")

        TVTest.remote.press(.select)
        waitForLabel(app.buttons["detail.action.watched"], "Mark Watched")
        capture("03-marked-unwatched-again")
    }

    func testInProgressMovieAudioAndSubtitles() {
        let app = openDetail(Self.deepField, type: "movie", style: "dark", spy: true)
        let primary = app.buttons["detail.action.primary"]
        XCTAssertTrue(primary.label.hasPrefix("Resume Deep Field"), primary.label)
        capture("01-resume-start-over")

        TVTest.remote.press(.right)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.startOver"))
        capture("02-start-over-focused")
        TVTest.remote.press(.select)
        XCTAssertTrue(app.alerts["Play \(Self.deepField)"].waitForExistence(timeout: 5))
        XCTAssertTrue(alertMessage(app).contains("resume=0"), alertMessage(app))
        TVTest.remote.press(.select)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.startOver"))

        TVTest.remote.press(.right)
        TVTest.remote.press(.right)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.audio"))
        capture("03-audio-focused")
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        capture("04-audio-menu")
        TVTest.remote.press(.down)
        TVTest.remote.press(.select)
        TVTest.settle(0.8)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.audio"))
        XCTAssertTrue(app.buttons["detail.action.audio"].label.contains("Spanish"), app.buttons["detail.action.audio"].label)

        TVTest.remote.press(.right)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.subtitles"))
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        capture("05-subtitle-menu")
        TVTest.remote.press(.down)
        TVTest.remote.press(.select)
        TVTest.settle(0.8)
        XCTAssertTrue(app.buttons["detail.action.subtitles"].label.contains("English"), app.buttons["detail.action.subtitles"].label)

        step(app, .left, until: "detail.action.primary")
        TVTest.remote.press(.select)
        XCTAssertTrue(app.alerts["Play \(Self.deepField)"].waitForExistence(timeout: 5))
        let message = alertMessage(app)
        XCTAssertFalse(message.contains("resume=0"), message)
        XCTAssertTrue(message.contains("audio=10023"), message)
        XCTAssertFalse(message.contains("subtitle=-"), message)
        capture("06-play-with-picks")
    }

    func testEpisodeDetailAndNavigation() {
        let app = openDetail(Self.saltRoadEpisode, type: "episode", style: "dark", spy: true)
        capture("01-episode-primary-focused")
        for identifier in ["startOver", "watched", "audio", "subtitles", "goToShow", "nextEpisode"] {
            TVTest.remote.press(.right)
            XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.\(identifier)"), identifier)
        }
        capture("02-next-episode-focused")

        TVTest.remote.press(.select)
        XCTAssertTrue(heroTitle(app, "Undertow").waitForExistence(timeout: 10))
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.primary"))
        TVTest.settle(1.0)
        capture("03-next-episode-opened")

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.nextEpisode"), "focus must return to Next Episode")
        TVTest.settle(0.5)
        capture("04-back-restores-focus")

        TVTest.remote.press(.left)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.goToShow"))
        TVTest.remote.press(.select)
        XCTAssertTrue(app.buttons["detail.action.primary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["detail.action.primary"].label.hasPrefix("Resume The Salt Road"), app.buttons["detail.action.primary"].label)
        TVTest.settle(1.0)
        capture("05-go-to-show")
    }

    func testSeasonSwitchShowsLoadingInsteadOfTheOldEpisodes() {
        resetMock()
        setSeason("3003", mode: "slow", seconds: 8)
        let app = openDetail(Self.saltRoad, type: "show", style: "dark", spy: true)
        pressSeasonChip(app, season: "3003")
        TVTest.settle(1.5)
        capture("01-season-loading")
        XCTAssertTrue(app.staticTexts["Season 3"].exists, "header should already name the new season")
        XCTAssertEqual(episodeCardCount(app), 0, "the previous season's episodes must not stay under the new header")
        XCTAssertTrue(app.descendants(matching: .any)["detail.episodes.loading"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["detail.episode.4019"].waitForExistence(timeout: 20))
        TVTest.settle(1.0)
        capture("02-season-loaded")
        XCTAssertFalse(app.descendants(matching: .any)["detail.episodes.loading"].exists)
    }

    func testFailedSeasonOffersRetryAndRecovers() {
        resetMock()
        setSeason("3004", mode: "fail")
        let app = openDetail(Self.saltRoad, type: "show", style: "dark", spy: true)
        pressSeasonChip(app, season: "3004")
        XCTAssertTrue(app.buttons["detail.episodes.retry"].waitForExistence(timeout: 15))
        TVTest.settle(0.8)
        capture("01-season-failed")
        XCTAssertEqual(episodeCardCount(app), 0)
        XCTAssertFalse(app.staticTexts["No episodes in this season"].exists, "a failed fetch is not an empty season")

        setSeason("3004", mode: "ok")
        TVTest.remote.press(.down)
        XCTAssertTrue(waitFocus(app.buttons["detail.episodes.retry"]))
        TVTest.remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["detail.episode.4027"].waitForExistence(timeout: 15))
        TVTest.settle(0.8)
        capture("02-season-recovered")
        XCTAssertFalse(app.buttons["detail.episodes.retry"].exists)
    }

    func testLateSeasonResponseIsIgnored() {
        resetMock()
        setSeason("3003", mode: "slow", seconds: 7)
        let app = openDetail(Self.saltRoad, type: "show", style: "dark", spy: true)
        pressSeasonChip(app, season: "3003")
        pressSeasonChip(app, season: "3004", entering: false)
        XCTAssertTrue(app.descendants(matching: .any)["detail.episode.4027"].waitForExistence(timeout: 15))
        TVTest.settle(9.0)
        XCTAssertTrue(app.staticTexts["Season 4"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["detail.episode.4019"].exists, "the slow season 3 response must not replace season 4")
        capture("01-season-4-after-late-response")
    }

    func testBackdropStaysDimmedWhileAShelfScrollsHorizontally() {
        let app = openDetail(Self.deepField, type: "movie", style: "dark")
        step(app, .down, until: "detail.cast.")
        TVTest.settle(1.2)
        let region = CGRect(x: 1650, y: 140, width: 240, height: 200)
        let before = meanLuminance(in: region)
        capture("01-cast-focused")
        for _ in 0 ..< 9 {
            TVTest.remote.press(.right)
            TVTest.settle(0.4)
        }
        TVTest.settle(1.0)
        let after = meanLuminance(in: region)
        capture("02-cast-scrolled-sideways")
        XCTAssertLessThanOrEqual(after, before + 0.02, "scrolling a shelf sideways must not brighten the backdrop (before \(before), after \(after))")
    }

    func testPrimaryActionFollowsProgressWhenMarkedWatched() {
        let app = openDetail("4095", type: "episode", style: "dark", spy: true)
        let primary = app.buttons["detail.action.primary"]
        XCTAssertTrue(primary.label.hasPrefix("Resume "), primary.label)
        XCTAssertTrue(app.buttons["detail.action.startOver"].exists)
        capture("01-in-progress")

        step(app, .right, until: "detail.action.watched")
        TVTest.remote.press(.select)
        waitForLabel(app.buttons["detail.action.watched"], "Mark Unwatched")
        TVTest.settle(1.0)
        XCTAssertTrue(primary.label.hasPrefix("Play "), "the primary action must follow the new state, got \(primary.label)")
        XCTAssertFalse(app.buttons["detail.action.startOver"].exists)
        XCTAssertTrue(waitFocus(app.buttons["detail.action.watched"]))
        capture("02-after-marking-watched")
    }

    func testMashingDirectionsKeepsFocusOnTheScreen() {
        let app = openDetail(Self.saltRoad, type: "show", style: "dark", spy: true)
        let moves: [XCUIRemote.Button] = [.down, .right, .right, .down, .down, .left, .up, .up, .right, .down, .down, .down, .up, .left, .left]
        for move in moves {
            TVTest.remote.press(move)
        }
        TVTest.settle(1.5)
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(focused.exists)
        XCTAssertTrue(focused.identifier.hasPrefix("detail.") || focused.identifier.hasPrefix("tv.chip."), "focus escaped to \(focused.identifier)")
        capture("01-after-mashing")
    }

    func testMenuPopsWhileTheShowIsLoading() {
        let app = openDetail(Self.saltRoadEpisode, type: "episode", style: "dark")
        step(app, .right, until: "detail.action.goToShow")
        TVTest.configureMock(["MOCK_LATENCY_MS": "8000"])
        TVTest.remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["detail.loading"].waitForExistence(timeout: 10))
        TVTest.settle(1.0)
        capture("01-show-loading-pushed")
        TVTest.remote.press(.menu)
        XCTAssertTrue(waitFocus(app.buttons["detail.action.goToShow"], timeout: 10), "Menu while loading must pop back to the episode")
        TVTest.configureMock()
        capture("02-popped-back")
    }

    func testShowDetailDark() {
        let app = openDetail(Self.saltRoad, type: "show", style: "dark", spy: true)
        XCTAssertTrue(app.buttons["detail.action.primary"].label.hasPrefix("Resume The Salt Road, season 2 episode 4"), app.buttons["detail.action.primary"].label)
        capture("01-show-primary-focused")

        TVTest.remote.press(.right)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.watched"))
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        capture("02-mark-watched-menu")
        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.watched"))

        step(app, .down, until: "tv.chip.")
        capture("03-season-chips-focused")
        TVTest.remote.press(.right)
        TVTest.settle(0.6)
        capture("04-season-3-focused-not-selected")
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        capture("05-season-3-selected")

        step(app, .down, until: "detail.episode.")
        TVTest.settle(0.8)
        capture("06-episode-focused")
        TVTest.remote.press(.select)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.firstMatch.label.hasPrefix("Play "), app.alerts.firstMatch.label)
        capture("07-episode-play-request")
        TVTest.remote.press(.select)

        step(app, .down, until: "detail.cast.")
        capture("08-cast-focused")
        step(app, .down, until: "detail.related.")
        capture("09-related-focused")
    }

    func testEpisodeContextMenuAndFocusRestore() {
        let app = openDetail(Self.saltRoad, type: "show", style: "dark", spy: true)
        step(app, .down, until: "tv.chip.")
        step(app, .down, until: "detail.episode.")
        TVTest.remote.press(.right)
        TVTest.settle(0.6)
        let focused = focusedEpisodeIdentifier(app)
        XCTAssertNotNil(focused)
        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1.0)
        capture("01-episode-menu")
        XCTAssertTrue(app.descendants(matching: .any)["Episode Details"].waitForExistence(timeout: 3), "context menu did not appear")
        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.buttons["detail.action.primary"].waitForExistence(timeout: 10))
        TVTest.settle(1.0)
        capture("02-episode-details-opened")
        TVTest.remote.press(.menu)
        if let focused {
            XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: focused), "focus must return to \(focused)")
        }
        TVTest.settle(0.5)
        capture("03-back-restores-episode-focus")
    }

    func testPlayPauseOnEpisodePlays() {
        let app = openDetail(Self.saltRoad, type: "show", style: "dark", spy: true)
        step(app, .down, until: "tv.chip.")
        step(app, .down, until: "detail.episode.")
        TVTest.remote.press(.playPause)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.firstMatch.label.hasPrefix("Play "))
    }

    func testLoadingSkeletonThenContent() {
        let app = openDetail("9406", type: "movie", style: "dark", waitForContent: false)
        XCTAssertTrue(app.descendants(matching: .any)["detail.loading"].waitForExistence(timeout: 5))
        TVTest.settle(0.5)
        capture("01-skeleton")
        enterContent(app, timeout: 40)
        capture("02-loaded")
    }

    func testErrorThenRetryRecovers() {
        resetMock()
        let app = openDetail("9405", type: "movie", style: "dark", waitForContent: false)
        enterState(app, button: "Retry")
        capture("01-error")
        TVTest.remote.press(.select)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.primary", timeout: 20))
        TVTest.settle(1.0)
        capture("02-recovered")
    }

    func testPermanentErrorKeepsOfferingRetry() {
        let app = openDetail("9404", type: "movie", style: "dark", waitForContent: false)
        enterState(app, button: "Retry")
        TVTest.remote.press(.select)
        XCTAssertTrue(waitFocus(app.buttons["Retry"], timeout: 20))
        TVTest.settle(0.8)
        capture("01-error-after-retry")
    }

    func testNotAvailable() {
        let app = openDetail("9410", type: "movie", style: "dark", waitForContent: false)
        enterState(app, button: "Go Back")
        capture("01-not-available")
        TVTest.remote.press(.select)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["Go Back"])
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "Go Back must leave the screen")
        XCTAssertTrue(app.tabBars.firstMatch.exists)
    }

    func testMovieDetailLight() {
        let app = openDetail(Self.deepField, type: "movie", style: "light")
        capture("01-light-movie-primary")
        step(app, .down, until: "detail.cast.")
        capture("02-light-cast")
        step(app, .down, until: "detail.information")
        TVTest.settle(0.8)
        capture("03-light-information")
    }

    func testShowDetailLight() {
        let app = openDetail(Self.saltRoad, type: "show", style: "light")
        capture("01-light-show-primary")
        step(app, .down, until: "tv.chip.")
        capture("02-light-chips")
        step(app, .down, until: "detail.episode.")
        TVTest.settle(0.8)
        capture("03-light-episodes")
    }

    private func openDetail(
        _ ratingKey: String,
        type: String,
        style: String,
        spy: Bool = false,
        waitForContent: Bool = true
    ) -> XCUIApplication {
        var environment = ["CRUCIBLE_STYLE": style]
        if spy { environment["CRUCIBLE_DETAIL_SPY"] = "1" }
        let app = TVTest.launch(extraEnvironment: environment)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        TVTest.settle()
        openFromOutside("crucible://item/\(ratingKey)?type=\(type)", in: app)
        if waitForContent { enterContent(app) }
        return app
    }

    /// A link that opens a screen leaves focus on the tab bar, so the first Down enters the content.
    private func enterContent(_ app: XCUIApplication, timeout: TimeInterval = 20) {
        XCTAssertTrue(app.buttons["detail.action.primary"].waitForExistence(timeout: timeout), "detail never appeared")
        TVTest.settle(1.0)
        if !TVTest.waitForFocus(on: app, identifier: "detail.action.primary", timeout: 2) {
            TVTest.remote.press(.down)
        }
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.primary", timeout: 10), "primary action never took focus")
        TVTest.settle(1.0)
    }

    /// Opens `link` through the system and answers the "Open in Crucible?" prompt. Under load the prompt
    /// and the screen can arrive late, so this waits until a detail screen or one of its states is
    /// there rather than for a fixed time, and a link opened late can never land on the next test.
    private func openFromOutside(_ link: String, in app: XCUIApplication) {
        let url = URL(string: link)!
        Task { _ = await UIApplication.shared.open(url) }
        let prompt = XCUIApplication(bundleIdentifier: "com.apple.PineBoard").buttons["Open"]
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if prompt.exists {
                TVTest.remote.press(.select)
                break
            }
            if detailHasArrived(app) { break }
            TVTest.settle(0.5)
        }
        TVTest.settle(0.5)
    }

    private func detailHasArrived(_ app: XCUIApplication) -> Bool {
        ["detail.action.primary", "Retry", "Go Back"].contains { app.buttons[$0].exists }
            || app.descendants(matching: .any)["detail.loading"].exists
    }

    /// A link that opens a screen leaves focus on the tab bar, so a state with a button takes focus on the first Down.
    private func enterState(_ app: XCUIApplication, button: String) {
        XCTAssertTrue(app.buttons[button].waitForExistence(timeout: 15), "\(button) never appeared")
        TVTest.settle(0.8)
        if !waitFocus(app.buttons[button], timeout: 2) {
            TVTest.remote.press(.down)
        }
        XCTAssertTrue(waitFocus(app.buttons[button], timeout: 5), "\(button) must take focus on the first Down from the tab bar")
    }

    /// Moves focus to the season chip with rating key `season` and presses it. Down from the action row lands on the first chip.
    private func pressSeasonChip(_ app: XCUIApplication, season: String, entering: Bool = true) {
        if entering { step(app, .down, until: "tv.chip.") }
        TVTest.settle(0.6)
        step(app, .right, until: "tv.chip.\(season)")
        capture("00-chip-\(season)-before-select")
        TVTest.remote.press(.select)
    }

    private func meanLuminance(in rect: CGRect) -> Double {
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { return 0 }
        let scale = Double(image.width) / 1920
        let crop = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        guard let part = image.cropping(to: crop) else { return 0 }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.interpolationQuality = .medium
        context.draw(part, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }

    private func setSeason(_ key: String, mode: String, seconds: Int = 5) {
        Self.callMock("/mock/detail-season?key=\(key)&mode=\(mode)&seconds=\(seconds)")
    }

    private func episodeCardCount(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.episode.")).count
    }

    private func resetMock() {
        Self.callMock("/mock/detail-reset")
    }

    private nonisolated static func callMock(_ path: String) {
        guard let base = ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"], let url = URL(string: base + path) else { return }
        TVTest.fetch(url)
    }

    private func step(_ app: XCUIApplication, _ button: XCUIRemote.Button, until prefix: String, limit: Int = 12) {
        for _ in 0 ..< limit {
            if focusedIdentifier(app, prefix: prefix) != nil { return }
            TVTest.remote.press(button)
            TVTest.settle(0.4)
        }
        XCTAssertNotNil(focusedIdentifier(app, prefix: prefix), "focus never reached \(prefix)")
    }

    private func focusedIdentifier(_ app: XCUIApplication, prefix: String) -> String? {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", prefix)).firstMatch
        return focused.exists ? focused.identifier : nil
    }

    private func focusedEpisodeIdentifier(_ app: XCUIApplication) -> String? {
        focusedIdentifier(app, prefix: "detail.episode.")
    }

    private func alertMessage(_ app: XCUIApplication) -> String {
        let texts = app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label)
        return texts.joined(separator: " ")
    }

    /// The hero reads as one accessibility element whose label starts with the title.
    private func heroTitle(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func waitFocus(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 10) {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, "label never became \(label), is \(element.label)")
    }

    private func capture(_ name: String) {
        TVTest.capture(name, in: self)
    }
}
