import XCTest

/// Closing the full player keeps the title playing in the bar above the tab bar: the viewer browses other tabs, opens the player
/// again from the bar, and ends playback with the bar's close button. Runs against the built-in demo, whose clips last 30 seconds, so the
/// tests pause the bar before the title can end and close the player for good.
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

    /// Shows the system player's controls with a tap clear of its play button and taps its close button, or swipes the player down where the button cannot be found.
    private func closeFullPlayer(_ app: XCUIApplication) {
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Close', 'Done', 'Dismiss'} OR identifier IN {'Close', 'Done'}")).firstMatch
        for _ in 0..<3 where !close.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            _ = close.waitForExistence(timeout: 2)
        }
        if close.isHittable {
            close.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        }
    }

    func testClosingThePlayerDocksItAboveTheTabBar() {
        let app = enterDemo()
        openTitle(app, "Afterglow")
        let play = app.buttons.matching(NSPredicate(format: "label == 'Play' OR label == 'Play Afterglow' OR label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "Afterglow has no Play button")
        play.tap()
        XCTAssertTrue(IOSTest.wait(for: play, "hittable == false", timeout: 40), "Play did not open the player")
        IOSTest.settle(2)
        IOSTest.capture("01-full-player", in: self)

        closeFullPlayer(app)
        let bar = IOSTest.element(app, "miniPlayer")
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "closing the player left no mini player")
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

        closeFullPlayer(app)
        XCTAssertTrue(IOSTest.wait(for: bar, "hittable == true", timeout: 20), "closing the reopened player did not dock it again")
        pause.tap()
        XCTAssertTrue(IOSTest.wait(for: pause, "label == 'Pause'", timeout: 10), "the mini player's play did nothing")

        IOSTest.element(app, "miniPlayer.close").tap()
        XCTAssertTrue(IOSTest.wait(for: bar, "exists == false", timeout: 20), "the mini player's close button left it up")
        IOSTest.capture("05-closed", in: self)
    }

    func testPlayingTheDockedTitleAgainOpensTheSamePlayer() {
        let app = enterDemo()
        openTitle(app, "Afterglow")
        let play = app.buttons.matching(NSPredicate(format: "label == 'Play' OR label == 'Play Afterglow' OR label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "Afterglow has no Play button")
        play.tap()
        XCTAssertTrue(IOSTest.wait(for: play, "hittable == false", timeout: 40), "Play did not open the player")
        IOSTest.settle(2)
        closeFullPlayer(app)
        let bar = IOSTest.element(app, "miniPlayer")
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "closing the player left no mini player")
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
        closeFullPlayer(app)
        XCTAssertTrue(IOSTest.wait(for: bar, "hittable == true", timeout: 20), "the same player did not dock again")
        IOSTest.element(app, "miniPlayer.close").tap()
        XCTAssertTrue(IOSTest.wait(for: bar, "exists == false", timeout: 20))
    }
}
