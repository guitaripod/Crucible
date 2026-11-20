import XCTest

/// The taste a viewer without Crucible Pro gets of What to Watch and of a written recap, driven without a mock server so the
/// same run works on a simulator and on a real iPhone or iPad.
///
/// The demo tests enter the built-in demo with its free version preview on, where the answers are prepared and nothing
/// leaves the device. `testOnThisDevicesOwnLibrary…` is for a device that is signed in for real: it starts nothing afresh
/// (no `CRUCIBLE_FRESH`, which would sign the device out), poses a viewer without Pro and a fresh taste for the launch
/// only (`CRUCIBLE_TASTE=posed` keeps nothing) and reads the library that is there, so it runs only when
/// `CRUCIBLE_OWN_LIBRARY=1` asks for it. A device takes UI tests only once UI automation is switched on at it; without
/// that, `CRUCIBLE_WALK` drives the same screens (`PhoneDebugWalk`).
@MainActor
final class TasteTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        IOSTest.element(app, identifier)
    }

    private func picks(_ app: XCUIApplication) -> XCUIElementQuery {
        app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'watch.pick.'"))
    }

    private func sealedPicks(_ app: XCUIApplication) -> XCUIElementQuery {
        app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'watch.sealed.'"))
    }

    /// Enters the demo as a new install and turns on Preview Free Version, so Crucible Pro's features are locked as on a
    /// free install and the demo's own tastes are still to come. A run that names the mock server for the other tests
    /// would sign in to it, and the demo starts from the welcome screen, so this launch leaves the mock out.
    private func enterDemoPreviewingTheFreeVersion() -> XCUIApplication {
        let app = IOSTest.launch(extraEnvironment: ["CRUCIBLE_PHONE_MOCK": "", "CRUCIBLE_PLEXTV": ""])
        let demo = element(app, "onboarding.demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 60), "Welcome never showed Try the demo")
        demo.tap()
        let start = element(app, "demo.intro.start")
        XCTAssertTrue(start.waitForExistence(timeout: 120), "the demo intro never appeared")
        start.tap()
        XCTAssertTrue(IOSTest.wait(for: start, "exists == false", timeout: 20), "the intro never closed")
        IOSTest.tab(app, "You").tap()
        let row = element(app, "you.demoFreePreview")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the demo offers Preview Free Version")
        let toggle = row.switches.firstMatch
        toggle.tap()
        XCTAssertTrue(IOSTest.wait(for: toggle, "value == '1'", timeout: 10), "the switch turned on")
        return app
    }

    /// Asserts that the answer on screen is a taste: one pick as it is, the others sealed, and the way to them.
    private func assertTaste(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(picks(app).count, 1, "a taste shows one pick as it is", file: file, line: line)
        XCTAssertGreaterThan(sealedPicks(app).count, 0, "a taste seals the other picks", file: file, line: line)
        XCTAssertTrue(element(app, "watch.unseal").exists, "a taste has no way to the sealed picks", file: file, line: line)
    }

    /// Scrolls the answer up and down and has XCTest count the frames that came late, which on a real device is the
    /// measure of whether the list stutters.
    private func measureScrolling(_ app: XCUIApplication) {
        let list = app.collectionViews.firstMatch
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            list.swipeUp(velocity: .fast)
            list.swipeDown(velocity: .fast)
        }
    }

    func testInTheFreePreviewWhatToWatchGivesATasteThatBuyingOpens() {
        let app = enterDemoPreviewingTheFreeVersion()
        IOSTest.tab(app, "Home").tap()
        let entry = element(app, "home.whatToWatch")
        XCTAssertTrue(entry.waitForExistence(timeout: 30), "Home has no What to Watch button in the demo")
        entry.tap()
        let example = element(app, "watch.example.1")
        XCTAssertTrue(example.waitForExistence(timeout: 10), "What to Watch never opened")
        let asked = Date()
        example.tap()
        XCTAssertTrue(picks(app).firstMatch.waitForExistence(timeout: 30), "the demo gave no picks: \(element(app, "watch.failure").label)")
        XCTContext.runActivity(named: String(format: "taste on screen %.2f s after asking", Date().timeIntervalSince(asked))) { _ in }
        IOSTest.settle(1.5)
        IOSTest.capture("01-taste", in: self)
        assertTaste(app)
        measureScrolling(app)

        element(app, "watch.example.0").tap()
        XCTAssertTrue(element(app, "paywall.offer.annual").waitForExistence(timeout: 30), "a second request did not open the paywall")
        IOSTest.settle(1)
        IOSTest.capture("02-second-request-paywall", in: self)
        element(app, "paywall.buy").tap()
        XCTAssertTrue(IOSTest.wait(for: element(app, "paywall.offer.annual"), "exists == false", timeout: 30), "the paywall never closed after the purchase")
        XCTAssertTrue(IOSTest.wait(for: element(app, "watch.unseal"), "exists == false", timeout: 30), "buying Crucible Pro left picks sealed")
        IOSTest.settle(1.5)
        IOSTest.capture("03-after-buying", in: self)
        XCTAssertGreaterThan(picks(app).count, 1, "every pick shows once Crucible Pro is on")
    }

    func testInTheFreePreviewARecapShowsHowItBeginsAndTheWayToTheRest() {
        let app = enterDemoPreviewingTheFreeVersion()
        IOSTest.tab(app, "Search").tap()
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
        let asked = Date()
        write.tap()
        let unseal = element(app, "previouslyOn.unseal")
        XCTAssertTrue(unseal.waitForExistence(timeout: 30), "no recap came back as a taste: \(element(app, "previouslyOn.text").label)")
        XCTContext.runActivity(named: String(format: "recap taste on screen %.2f s after asking", Date().timeIntervalSince(asked))) { _ in }
        IOSTest.settle(1)
        IOSTest.capture("04-recap-taste", in: self)
        let opening = element(app, "previouslyOn.text").label
        XCTAssertGreaterThan(opening.count, 20)

        unseal.tap()
        XCTAssertTrue(element(app, "paywall.offer.annual").waitForExistence(timeout: 30), "Read the Whole Recap did not open the paywall")
        element(app, "paywall.buy").tap()
        XCTAssertTrue(IOSTest.wait(for: unseal, "exists == false", timeout: 30), "buying Crucible Pro did not open the rest of the recap")
        IOSTest.settle(1)
        IOSTest.capture("05-recap-after-buying", in: self)
        XCTAssertGreaterThan(element(app, "previouslyOn.text").label.count, opening.count, "the whole recap is longer than how it begins")
    }

    func testOnThisDevicesOwnLibraryWhatToWatchGivesATaste() throws {
        guard ProcessInfo.processInfo.environment["CRUCIBLE_OWN_LIBRARY"] == "1" else {
            throw XCTSkip("Runs on a signed-in device when CRUCIBLE_OWN_LIBRARY=1 asks for it")
        }
        let app = IOSTest.launch(fresh: false, extraEnvironment: ["CRUCIBLE_PRO": "free", "CRUCIBLE_TASTE": "posed", "CRUCIBLE_BRAIN": "ok", "CRUCIBLE_PHONE_MOCK": ""])
        let entry = element(app, "home.whatToWatch")
        XCTAssertTrue(entry.waitForExistence(timeout: 90), "Home never showed its What to Watch button")
        entry.tap()
        let field = element(app, "watch.field")
        XCTAssertTrue(field.waitForExistence(timeout: 10), "What to Watch never opened")
        field.tap()
        field.typeText("something light for tonight")
        let asked = Date()
        element(app, "watch.suggest").tap()
        XCTAssertTrue(picks(app).firstMatch.waitForExistence(timeout: 90), "no pick came back: \(element(app, "watch.failure").label)")
        XCTContext.runActivity(named: String(format: "taste on screen %.2f s after asking", Date().timeIntervalSince(asked))) { _ in }
        IOSTest.settle(2)
        IOSTest.capture("06-own-library-taste", in: self)
        assertTaste(app)
        measureScrolling(app)
        IOSTest.capture("07-own-library-after-scrolling", in: self)
    }
}
