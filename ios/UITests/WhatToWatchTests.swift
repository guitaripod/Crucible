import XCTest

/// What to Watch and a described Previously On on iPhone, against the mock Plex server named in `CRUCIBLE_PHONE_MOCK`
/// (`tv.sh mock-up` prints it). With `CRUCIBLE_BRAIN=ok` the hosted model is scripted and the run is the same every
/// time; without it the App Store build's own model answers over the network, which is the end-to-end check.
@MainActor
final class WhatToWatchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(pro: String) throws -> XCUIApplication {
        guard let mock = ProcessInfo.processInfo.environment["CRUCIBLE_PHONE_MOCK"] else {
            throw XCTSkip("Needs the mock server named in CRUCIBLE_PHONE_MOCK")
        }
        let app = IOSTest.launch(extraEnvironment: ["CRUCIBLE_PHONE_MOCK": mock, "CRUCIBLE_PLEXTV": mock, "CRUCIBLE_PRO": pro])
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60), "the app never reached its tabs")
        return app
    }

    private func openWhatToWatch(_ app: XCUIApplication) {
        let entry = IOSTest.element(app, "home.whatToWatch")
        XCTAssertTrue(entry.waitForExistence(timeout: 30), "Home has no What to Watch button")
        entry.tap()
        XCTAssertTrue(IOSTest.element(app, "watch.field").waitForExistence(timeout: 10), "What to Watch never opened")
    }

    func testASentenceBecomesPicksAndAPickOpensItsPage() throws {
        let app = try launch(pro: "lifetime")
        IOSTest.capture("home", in: self)
        openWhatToWatch(app)
        IOSTest.settle(1)
        IOSTest.capture("asking", in: self)
        let field = IOSTest.element(app, "watch.field")
        field.tap()
        field.typeText("something light for tonight")
        IOSTest.capture("typed", in: self)
        IOSTest.element(app, "watch.suggest").tap()
        let pick = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'watch.pick.'")).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 90), "no pick came back: \(IOSTest.element(app, "watch.failure").label)")
        IOSTest.settle(2)
        IOSTest.capture("picks", in: self)
        XCTAssertGreaterThan(app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'watch.pick.'")).count, 0)
        pick.tap()
        XCTAssertTrue(IOSTest.element(app, "watch.field").waitForNonExistence(timeout: 15), "the pick's page never opened")
        IOSTest.settle(2)
        IOSTest.capture("pick-page", in: self)
    }

    func testWithoutProAskingOpensThePaywallThatNamesIt() throws {
        let app = try launch(pro: "free")
        openWhatToWatch(app)
        let field = IOSTest.element(app, "watch.field")
        field.tap()
        field.typeText("a film for tonight")
        IOSTest.element(app, "watch.suggest").tap()
        XCTAssertTrue(IOSTest.element(app, "paywall.offer.annual").waitForExistence(timeout: 30), "asking without Crucible Pro did not open the paywall")
        IOSTest.settle(1)
        IOSTest.capture("paywall", in: self)
        XCTAssertTrue(app.staticTexts["What to Watch"].exists, "the paywall does not name What to Watch")
    }

    func testAShowWithoutACompanionShowsItsDescriptionsAndWritesARecap() throws {
        let app = try launch(pro: "lifetime")
        IOSTest.tab(app, "Search").tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30), "the search field never appeared")
        search.tap()
        search.typeText("Paper Lanterns")
        let result = app.collectionViews.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Paper Lanterns'")).firstMatch
        if !result.waitForExistence(timeout: 30) { IOSTest.capture("search", in: self) }
        XCTAssertTrue(result.exists, "search never found Paper Lanterns")
        result.tap()
        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 30), "the show page never opened")
        more.tap()
        let entry = app.buttons["Previously On"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "the show's menu has no Previously On")
        entry.tap()
        XCTAssertTrue(IOSTest.element(app, "previouslyOn.write").waitForExistence(timeout: 15), "the sheet has no Write a Recap button")
        IOSTest.settle(1)
        IOSTest.capture("descriptions", in: self)
        IOSTest.element(app, "previouslyOn.write").tap()
        let text = IOSTest.element(app, "previouslyOn.text")
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(IOSTest.element(app, "previouslyOn.write").waitForNonExistence(timeout: 90), "no recap came back: \(text.label)")
        IOSTest.settle(1)
        IOSTest.capture("recap", in: self)
        XCTAssertGreaterThan(text.label.count, 40)
    }
}
