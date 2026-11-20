import XCTest

/// Swiping the full player down keeps the title playing in the bar above the tab bar: the viewer browses other tabs, opens the player
/// again from the bar, and ends playback with the bar's close button. The full player's own close button ends playback at once, with no
/// bar left behind. Runs against the built-in demo, whose clips last 30 seconds, so the tests pause the bar before the title can end.
@MainActor
final class MiniPlayerTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func enterDemo() -> XCUIApplication {
        let app = IOSTest.launch()
        let demo = IOSTest.element(app, "onboarding.demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 120), "Welcome never showed Try the demo")
        demo.tap()
        let start = IOSTest.element(app, "demo.intro.start")
        XCTAssertTrue(start.waitForExistence(timeout: 180), "the demo intro never appeared")
        start.tap()
        XCTAssertTrue(IOSTest.wait(for: start, "exists == false OR hittable == false", timeout: 30), "the intro never closed")
        IOSTest.settle(2)
        return app
    }

    private func openTitle(_ app: XCUIApplication, _ title: String) {
        let search = IOSTest.tab(app, "Search")
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        let field = app.searchFields.firstMatch
        for _ in 0..<3 where !field.exists {
            search.tap()
            _ = field.waitForExistence(timeout: 10)
        }
        field.tap()
        field.typeText(title)
        let result = app.cells.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 60), "search found no \(title)")
        result.tap()
    }

    /// Shows the system player's controls with a tap clear of its play button and taps its close button where it stands, again if the
    /// controls faded out before the tap landed, until the player has gone.
    private func closeFullPlayer(_ app: XCUIApplication) {
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Close', 'Done', 'Dismiss'} OR identifier IN {'Close', 'Done'}")).firstMatch
        for _ in 0..<4 {
            if !close.isHittable {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
                _ = IOSTest.wait(for: close, "hittable == true", timeout: 2)
            }
            guard close.exists else { continue }
            let frame = close.frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            if IOSTest.wait(for: close, "exists == false", timeout: 3) { return }
        }
        XCTFail("the full player's close button never closed it")
    }

    /// Flicks the full player down from its upper half, the gesture that shrinks it into the bar: a short fast drag, as a thumb does it,
    /// so the player finishes the trip on its own after the finger lifts.
    private func swipeFullPlayerDown(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)), withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func playAfterglow(_ app: XCUIApplication) -> XCUIElement {
        openTitle(app, "Afterglow")
        let play = app.buttons.matching(NSPredicate(format: "label == 'Play' OR label == 'Play Afterglow' OR label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "Afterglow has no Play button")
        play.tap()
        XCTAssertTrue(IOSTest.wait(for: play, "hittable == false", timeout: 40), "Play did not open the player")
        IOSTest.settle(2)
        return play
    }

    func testClosingThePlayerEndsPlayback() {
        let app = enterDemo()
        let play = playAfterglow(app)
        closeFullPlayer(app)
        XCTAssertTrue(IOSTest.wait(for: play, "hittable == true", timeout: 20), "closing the player did not return to the title")
        IOSTest.settle(3)
        XCTAssertFalse(IOSTest.element(app, "miniPlayer").exists, "closing the player left it playing in the mini player")
        IOSTest.capture("01-closed-for-good", in: self)
    }

    func testSwipingThePlayerDownDocksItAboveTheTabBar() {
        let app = enterDemo()
        _ = playAfterglow(app)
        IOSTest.capture("01-full-player", in: self)

        swipeFullPlayerDown(app)
        let bar = IOSTest.element(app, "miniPlayer")
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "swiping the player down left no mini player")
        let pause = IOSTest.element(app, "miniPlayer.playPause")
        XCTAssertTrue(IOSTest.wait(for: pause, "label == 'Pause'", timeout: 20), "the docked player stopped playing")
        IOSTest.capture("02-docked-on-detail", in: self)
        pause.tap()
        XCTAssertTrue(IOSTest.wait(for: pause, "label == 'Play'", timeout: 10), "the mini player's pause did nothing")

        IOSTest.tab(app, "Home").tap()
        IOSTest.settle(2)
        XCTAssertTrue(bar.isHittable, "the mini player did not stay on another tab")
        IOSTest.capture("03-docked-on-home", in: self)

        IOSTest.element(app, "miniPlayer.expand").tap()
        XCTAssertTrue(IOSTest.wait(for: bar, "hittable == false", timeout: 20), "tapping the mini player did not open the player")
        IOSTest.settle(2)
        IOSTest.capture("04-expanded-again", in: self)

        swipeFullPlayerDown(app)
        XCTAssertTrue(IOSTest.wait(for: bar, "hittable == true", timeout: 20), "swiping the reopened player down did not dock it again")
        pause.tap()
        XCTAssertTrue(IOSTest.wait(for: pause, "label == 'Pause'", timeout: 10), "the mini player's play did nothing")
        IOSTest.capture("05-docked-again", in: self)

        IOSTest.element(app, "miniPlayer.expand").tap()
        XCTAssertTrue(IOSTest.wait(for: bar, "hittable == false", timeout: 20), "tapping the mini player did not open the player")
        IOSTest.settle(1)
        closeFullPlayer(app)
        XCTAssertTrue(IOSTest.wait(for: bar, "exists == false", timeout: 20), "closing the reopened player left it in the mini player")
        IOSTest.capture("06-closed", in: self)
    }

    func testTheMiniPlayersCloseButtonEndsPlayback() {
        let app = enterDemo()
        _ = playAfterglow(app)
        swipeFullPlayerDown(app)
        let bar = IOSTest.element(app, "miniPlayer")
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "swiping the player down left no mini player")
        IOSTest.element(app, "miniPlayer.close").tap()
        XCTAssertTrue(IOSTest.wait(for: bar, "exists == false", timeout: 20), "the mini player's close button left it up")
    }

    func testPlayingTheDockedTitleAgainOpensTheSamePlayer() {
        let app = enterDemo()
        _ = playAfterglow(app)
        swipeFullPlayerDown(app)
        let bar = IOSTest.element(app, "miniPlayer")
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "swiping the player down left no mini player")
        let pause = IOSTest.element(app, "miniPlayer.playPause")
        pause.tap()
        XCTAssertTrue(IOSTest.wait(for: pause, "label == 'Play'", timeout: 10), "the demo clip is short, so the test pauses it before it ends")

        let again = app.buttons.matching(NSPredicate(
            format: "(label == 'Play' OR label == 'Play Afterglow' OR label BEGINSWITH 'Resume') AND identifier != 'miniPlayer.playPause'"
        )).firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 20))
        again.tap()
        XCTAssertTrue(IOSTest.wait(for: bar, "hittable == false", timeout: 20), "playing the docked title again did not open the player")
        IOSTest.settle(1)
        swipeFullPlayerDown(app)
        XCTAssertTrue(IOSTest.wait(for: bar, "hittable == true", timeout: 20), "the same player did not dock again")
        IOSTest.element(app, "miniPlayer.close").tap()
        XCTAssertTrue(IOSTest.wait(for: bar, "exists == false", timeout: 20))
    }
}
