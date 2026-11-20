import XCTest

/// What to Watch and a described Previously On on iPhone and iPad, against the mock Plex server named in `CRUCIBLE_PHONE_MOCK`
/// (`tv.sh mock-up` prints it). With `CRUCIBLE_BRAIN=ok` the hosted model is scripted and the run is the same every
/// time; without it the App Store build's own model answers over the network, which is the end-to-end check.
/// A launch has used its tastes of the AI features unless a test asks for them fresh.
@MainActor
final class WhatToWatchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(pro: String, taste: String = "used") throws -> XCUIApplication {
        guard let mock = ProcessInfo.processInfo.environment["CRUCIBLE_PHONE_MOCK"] else {
            throw XCTSkip("Needs the mock server named in CRUCIBLE_PHONE_MOCK")
        }
        let app = IOSTest.launch(extraEnvironment: ["CRUCIBLE_PHONE_MOCK": mock, "CRUCIBLE_PLEXTV": mock, "CRUCIBLE_PRO": pro, "CRUCIBLE_TASTE": taste])
        if !IOSTest.element(app, "home.whatToWatch").waitForExistence(timeout: 90) { IOSTest.capture("launch", in: self) }
        XCTAssertTrue(IOSTest.element(app, "home.whatToWatch").exists, "Home never showed its What to Watch button")
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

    func testWithoutProTheFirstAnswerShowsOnePickAndSealsTheOthersUntilProIsBought() throws {
        let app = try launch(pro: "free", taste: "fresh")
        openWhatToWatch(app)
        let field = IOSTest.element(app, "watch.field")
        field.tap()
        field.typeText("something light for tonight")
        IOSTest.element(app, "watch.suggest").tap()
        let picks = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'watch.pick.'"))
        let sealed = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'watch.sealed.'"))
        XCTAssertTrue(picks.firstMatch.waitForExistence(timeout: 90), "no pick came back: \(IOSTest.element(app, "watch.failure").label)")
        IOSTest.settle(2)
        IOSTest.capture("taste", in: self)
        XCTAssertEqual(picks.count, 1, "a taste shows one pick as it is")
        XCTAssertGreaterThan(sealed.count, 0, "a taste seals the other picks")
        let sealedTitle = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Opens with Crucible Pro'")).firstMatch
        XCTAssertTrue(sealedTitle.exists, "a sealed pick does not say what opens it")

        IOSTest.element(app, "watch.unseal").tap()
        XCTAssertTrue(IOSTest.element(app, "paywall.offer.annual").waitForExistence(timeout: 30), "See Every Pick did not open the paywall")
        IOSTest.settle(1)
        IOSTest.capture("taste-paywall", in: self)
        XCTAssertTrue(app.staticTexts["What to Watch"].exists, "the paywall does not name What to Watch")

        IOSTest.element(app, "paywall.buy").tap()
        XCTAssertTrue(IOSTest.wait(for: sealed.firstMatch, "exists == false", timeout: 30), "buying Crucible Pro did not open the sealed picks")
        IOSTest.settle(1)
        IOSTest.capture("taste-opened", in: self)
        XCTAssertGreaterThan(picks.count, 1, "every pick shows once Crucible Pro is on")
        XCTAssertFalse(IOSTest.element(app, "watch.unseal").exists)
    }

    func testAfterTheTasteAskingAgainOpensThePaywall() throws {
        let app = try launch(pro: "free", taste: "fresh")
        openWhatToWatch(app)
        let field = IOSTest.element(app, "watch.field")
        field.tap()
        field.typeText("something light for tonight")
        IOSTest.element(app, "watch.suggest").tap()
        let pick = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'watch.pick.'")).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 90), "no pick came back: \(IOSTest.element(app, "watch.failure").label)")
        field.tap()
        field.typeText(" and short")
        IOSTest.element(app, "watch.suggest").tap()
        XCTAssertTrue(IOSTest.element(app, "paywall.offer.annual").waitForExistence(timeout: 30), "a second request without Crucible Pro did not open the paywall")
    }

    private func openPreviouslyOn(_ app: XCUIApplication) {
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
    }

    func testWithoutProTheFirstRecapShowsHowItBeginsAndSealsTheRestUntilProIsBought() throws {
        let app = try launch(pro: "free", taste: "fresh")
        openPreviouslyOn(app)
        IOSTest.element(app, "previouslyOn.write").tap()
        let text = IOSTest.element(app, "previouslyOn.text")
        let unseal = IOSTest.element(app, "previouslyOn.unseal")
        XCTAssertTrue(unseal.waitForExistence(timeout: 90), "no recap came back as a taste: \(text.label)")
        IOSTest.settle(1)
        IOSTest.capture("recap-taste", in: self)
        let opening = text.label
        XCTAssertGreaterThan(opening.count, 20)

        unseal.tap()
        XCTAssertTrue(IOSTest.element(app, "paywall.offer.annual").waitForExistence(timeout: 30), "Read the Whole Recap did not open the paywall")
        IOSTest.settle(1)
        IOSTest.capture("recap-taste-paywall", in: self)
        IOSTest.element(app, "paywall.buy").tap()
        XCTAssertTrue(IOSTest.wait(for: unseal, "exists == false", timeout: 30), "buying Crucible Pro did not open the rest of the recap")
        IOSTest.settle(1)
        IOSTest.capture("recap-opened", in: self)
        XCTAssertGreaterThan(text.label.count, opening.count, "the whole recap is longer than how it begins")
    }

    func testAShowWithoutACompanionShowsItsDescriptionsAndWritesARecap() throws {
        let app = try launch(pro: "lifetime")
        openPreviouslyOn(app)
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
