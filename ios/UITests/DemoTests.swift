import XCTest

/// Drives the built-in demo on the iPhone against the real in-app demo library. Every launch is a new install (`CRUCIBLE_FRESH=1`), so
/// the first visit to a screen is the first visit after launch.
@MainActor
final class DemoTests: XCTestCase {
    private static let query = "the"

    override func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        IOSTest.element(app, identifier)
    }

    private func enterDemo() -> XCUIApplication {
        let app = IOSTest.launch()
        let demo = element(app, "onboarding.demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 60), "Welcome never showed Try the demo")
        demo.tap()
        let start = element(app, "demo.intro.start")
        XCTAssertTrue(start.waitForExistence(timeout: 120), "the demo intro never appeared")
        start.tap()
        XCTAssertTrue(app.tabBars.buttons["Search"].waitForExistence(timeout: 30), "the tab bar never appeared")
        XCTAssertTrue(IOSTest.wait(for: start, "exists == false", timeout: 20), "the intro never closed")
        IOSTest.settle(1.5)
        return app
    }

    private func assertRunning(_ app: XCUIApplication, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "the app is no longer running after \(step)", file: file, line: line)
    }

    private func scopeButton(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let segmented = app.segmentedControls.buttons[title]
        return segmented.exists ? segmented : app.buttons[title]
    }

    func testFirstVisitToSearchTypingAndScopesDoNotCrash() {
        let app = enterDemo()
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the search field never appeared")
        IOSTest.settle(2)
        assertRunning(app, "opening Search")
        IOSTest.capture("01-search-first-visit", in: self)

        field.tap()
        field.typeText(Self.query)
        IOSTest.settle(3)
        assertRunning(app, "typing the query")
        IOSTest.capture("02-search-results", in: self)

        for scope in ["Movies", "Shows", "Episodes", "All"] {
            let button = scopeButton(app, scope)
            XCTAssertTrue(button.waitForExistence(timeout: 10), "the \(scope) scope button is missing")
            button.tap()
            IOSTest.settle(1.5)
            assertRunning(app, "choosing the \(scope) scope")
        }
        IOSTest.capture("03-search-after-scopes", in: self)
    }

    func testTourSearchShowMeFillsTheFieldWithoutCrashing() {
        let app = enterDemo()
        app.tabBars.buttons["You"].tap()
        let tour = element(app, "you.demo")
        XCTAssertTrue(tour.waitForExistence(timeout: 20), "the You tab has no Demo row")
        tour.tap()
        let step = element(app, "demo.step.search")
        XCTAssertTrue(step.waitForExistence(timeout: 20), "the tour has no Search step")
        step.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Show me never reached the search field")
        IOSTest.settle(3)
        assertRunning(app, "Show me on the Search step")
        IOSTest.capture("01-show-me-search", in: self)
        XCTAssertFalse((field.value as? String ?? "").isEmpty, "Show me should type a sample into the search field")
    }

    func testSearchOpenedAtOnceAfterTheIntroSurvivesRapidTypingAndScopeChanges() {
        let app = IOSTest.launch()
        let demo = element(app, "onboarding.demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 60), "Welcome never showed Try the demo")
        demo.tap()
        let start = element(app, "demo.intro.start")
        XCTAssertTrue(start.waitForExistence(timeout: 120), "the demo intro never appeared")
        start.tap()
        let search = app.tabBars.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 30), "the tab bar never appeared")
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the search field never appeared")
        field.tap()
        field.typeText(Self.query)
        for scope in ["Shows", "Episodes", "Movies", "All", "Shows", "All"] {
            let button = scopeButton(app, scope)
            if button.waitForExistence(timeout: 10) { button.tap() }
        }
        field.typeText("y")
        IOSTest.settle(3)
        assertRunning(app, "rapid typing and scope changes")
        IOSTest.capture("01-search-rapid", in: self)
    }
}
