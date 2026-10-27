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
