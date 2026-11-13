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

    private func enterDemo(extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = IOSTest.launch(extraEnvironment: extraEnvironment)
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

    /// Fails when the finale sheet is on screen or the app stopped running, naming whether the keyboard was still up.
    private func assertNoFinaleOverKeyboard(_ app: XCUIApplication, _ moment: String, file: StaticString = #filePath, line: UInt = #line) {
        assertRunning(app, moment, file: file, line: line)
        let finale = element(app, "demo.finale.keep")
        XCTAssertFalse(finale.exists, "the demo finale landed \(moment) while the keyboard was \(app.keyboards.firstMatch.exists ? "up" : "down")", file: file, line: line)
    }

    /// Lets `seconds` pass in short steps, checking after each that no finale showed up and the app is still running.
    private func watchForNoFinale(_ app: XCUIApplication, seconds: TimeInterval, _ moment: String, file: StaticString = #filePath, line: UInt = #line) {
        let steps = Int(seconds / 0.5)
        for _ in 0..<steps {
            IOSTest.settle(0.5)
            assertNoFinaleOverKeyboard(app, moment, file: file, line: line)
        }
    }

    func testFinaleWaitsForTheKeyboardWhileTypingThenAppearsAndKeepExploringKeepsTheResults() {
        let app = enterDemo(extraEnvironment: ["CRUCIBLE_DEMO_DONE": "play,browse,statistics"])
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the search field never appeared")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard never came up")
        assertNoFinaleOverKeyboard(app, "after tapping the search field")

        for letter in ["t", "h", "e"] {
            field.typeText(letter)
            IOSTest.settle(0.6)
            assertNoFinaleOverKeyboard(app, "after typing \(letter)")
        }
        IOSTest.capture("01-typed-with-keyboard-up", in: self)
        watchForNoFinale(app, seconds: 4, "in the 4 seconds after the last letter")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard should still be up")
        IOSTest.capture("02-four-seconds-later", in: self)

        let resultsBefore = app.collectionViews.firstMatch.cells.count
        XCTAssertGreaterThan(resultsBefore, 0, "the search shows no results")

        field.typeText("\n")
        let finale = element(app, "demo.finale.keep")
        XCTAssertTrue(finale.waitForExistence(timeout: 10), "the finale never appeared after the keyboard went away")
        assertRunning(app, "the finale appearing")
        IOSTest.settle(1)
        IOSTest.capture("03-finale", in: self)

        finale.tap()
        XCTAssertTrue(IOSTest.wait(for: finale, "exists == false", timeout: 10), "Keep exploring did not close the finale")
        IOSTest.settle(1)
        assertRunning(app, "closing the finale")
        XCTAssertGreaterThan(app.collectionViews.firstMatch.cells.count, 0, "the results disappeared with the finale")
        IOSTest.capture("04-after-keep-exploring", in: self)
    }

    func testWhatToWatchAnswersItsExamplesFromPreparedPicks() {
        let app = enterDemo()
        let entry = element(app, "home.whatToWatch")
        XCTAssertTrue(entry.waitForExistence(timeout: 30), "Home has no What to Watch button in the demo")
        entry.tap()
        let light = element(app, "watch.example.1")
        XCTAssertTrue(light.waitForExistence(timeout: 10), "What to Watch never opened")
        XCTAssertFalse(element(app, "watch.field").exists, "the demo shows a field for a request it cannot answer")
        IOSTest.settle(1)
        IOSTest.capture("watch-asking", in: self)
        light.tap()
        let picks = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'watch.pick.'"))
        XCTAssertTrue(picks.firstMatch.waitForExistence(timeout: 30), "the demo gave no picks: \(element(app, "watch.failure").label)")
        IOSTest.settle(1.5)
        XCTAssertGreaterThanOrEqual(picks.count, 3)
        XCTAssertTrue(light.isSelected, "the request that was asked is not marked")
        IOSTest.capture("watch-picks", in: self)
        element(app, "watch.example.0").tap()
        XCTAssertTrue(IOSTest.wait(for: element(app, "watch.example.0"), "selected == true", timeout: 30), "a second request was not answered")
        IOSTest.settle(1.5)
        XCTAssertGreaterThanOrEqual(picks.count, 3)
        IOSTest.capture("watch-film-picks", in: self)
        picks.firstMatch.tap()
        XCTAssertTrue(light.waitForNonExistence(timeout: 15), "the pick's page never opened")
        assertRunning(app, "opening a pick")
    }

    func testAShowStartedInTheDemoWritesItsPreparedRecap() {
        let app = enterDemo()
        app.tabBars.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30), "the search field never appeared")
        search.tap()
        search.typeText("Paper Lanterns")
        let result = app.collectionViews.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Paper Lanterns'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "search never found Paper Lanterns")
        result.tap()
        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 30), "the show page never opened")
        more.tap()
        let entry = app.buttons["Previously On"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "the show's menu has no Previously On")
        entry.tap()
        let write = element(app, "previouslyOn.write")
        XCTAssertTrue(write.waitForExistence(timeout: 15), "the demo offers no recap of the episodes it starts with")
        IOSTest.settle(1)
        IOSTest.capture("recap-offer", in: self)
        write.tap()
        let text = element(app, "previouslyOn.text")
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(write.waitForNonExistence(timeout: 30), "no recap came back: \(text.label)")
        IOSTest.settle(1)
        IOSTest.capture("recap", in: self)
        XCTAssertGreaterThan(text.label.count, 40)
    }
}
