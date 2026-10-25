import XCTest

/// The built-in demo on an iPad, shared by the iPad tests and the App Store captures.
@MainActor
enum IPadDemo {
    static func homeTitle(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars["Home"]
    }

    static func backButton(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons["BackButton"].firstMatch
    }

    /// Launches a new install, enters the demo and waits for Home.
    static func enter(extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = IOSTest.launch(extraEnvironment: extraEnvironment)
        let demo = IOSTest.element(app, "onboarding.demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 120), "Welcome never showed Try the demo")
        demo.tap()
        let start = IOSTest.element(app, "demo.intro.start")
        XCTAssertTrue(start.waitForExistence(timeout: 180), "the demo intro never appeared")
        start.tap()
        XCTAssertTrue(IOSTest.wait(for: start, "exists == false OR hittable == false", timeout: 30), "the intro never closed")
        XCTAssertTrue(IOSTest.wait(for: homeTitle(app), "exists == true", timeout: 120), "Home never appeared")
        IOSTest.settle(2)
        return app
    }

    /// The sidebar's entry for the first of `titles` on screen: a button, a cell or a text with that name.
    static func libraryEntry(_ app: XCUIApplication, _ titles: [String]) -> XCUIElement? {
        for title in titles {
            for candidate in [app.buttons[title], app.cells[title], app.staticTexts[title]] where candidate.exists {
                return candidate
            }
        }
        return nil
    }
}
