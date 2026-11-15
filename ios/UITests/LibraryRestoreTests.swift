import XCTest

/// The Library tab is a tab group, so it has no root screen of its own: what a restored window must show is the library child it
/// was on, not an empty group.
@MainActor
final class LibraryRestoreTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func enterDemo(_ app: XCUIApplication) {
        let demo = IOSTest.element(app, "onboarding.demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 120), "Welcome never showed Try the demo")
        demo.tap()
        let start = IOSTest.element(app, "demo.intro.start")
        XCTAssertTrue(start.waitForExistence(timeout: 180), "the demo intro never appeared")
        start.tap()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 60), "the tab bar never appeared")
        IOSTest.settle(1.5)
    }

    private func showMovies(_ app: XCUIApplication) {
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars["Movies"].waitForExistence(timeout: 60), "the Library tab showed no library")
        IOSTest.settle(2)
    }

    /// Holding the Library tab offers the library title's menu, from any tab, and a library chosen there opens on the Library tab.
    func testHoldingTheLibraryTabSwitchesLibraries() {
        let app = IOSTest.launch()
        enterDemo(app)
        app.tabBars.buttons["Library"].press(forDuration: 1.2)
        IOSTest.capture("01-held", in: self)
        let shows = app.collectionViews.buttons["TV Shows"].firstMatch
        XCTAssertTrue(shows.waitForExistence(timeout: 10), "holding the Library tab showed no menu of libraries")
        IOSTest.capture("02-held-library-tab", in: self)
        shows.tap()
        XCTAssertTrue(app.navigationBars["TV Shows"].waitForExistence(timeout: 60), "choosing TV Shows from the held tab did not show it")
        IOSTest.settle(1.5)
        IOSTest.tab(app, "Library").press(forDuration: 1.2)
        let movies = app.collectionViews.buttons["Movies"].firstMatch
        XCTAssertTrue(movies.waitForExistence(timeout: 10), "holding the Library tab on a library showed no menu")
        XCTAssertTrue(app.collectionViews.buttons["Collections"].exists, "the held tab offers the shown library's collections")
        IOSTest.capture("03-held-on-a-library", in: self)
        movies.tap()
        XCTAssertTrue(app.navigationBars["Movies"].waitForExistence(timeout: 60), "choosing Movies from the held tab did not show it")
    }

    func testLibraryIsStillShowingAfterRelaunch() {
        let app = IOSTest.launch()
        enterDemo(app)
        showMovies(app)
        IOSTest.capture("01-library", in: self)

        IOSTest.settle(1)
        XCUIDevice.shared.press(.home)
        IOSTest.settle(2)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "CRUCIBLE_FRESH")
        app.launch()

        XCTAssertEqual(app.state, .runningForeground, "the app did not come back")
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 60), "the tab bar never came back")
        XCTAssertTrue(
            app.navigationBars["Movies"].waitForExistence(timeout: 60),
            "the Library tab came back empty instead of on Movies"
        )
        IOSTest.settle(2)
        IOSTest.capture("02-restored", in: self)
    }
}
