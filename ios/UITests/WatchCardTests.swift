import XCTest

/// Makes a watch card in the built-in demo from a movie's More menu: the composer opens on the card, rating it there
/// puts the stars on the card, the words, the format and the look change it, and Share hands it to the share sheet.
@MainActor
final class WatchCardTests: XCTestCase {
    private static let title = "Low Tide"

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

    private func openDetail(_ app: XCUIApplication) {
        let field = app.searchFields.firstMatch
        for _ in 0..<3 where !field.exists {
            let search = app.tabBars.buttons["Search"]
            if search.waitForExistence(timeout: 10) {
                search.tap()
            } else {
                app.typeKey("f", modifierFlags: .command)
            }
            _ = field.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the search field never appeared")
        field.tap()
        field.typeText(Self.title)
        let result = app.cells.containing(NSPredicate(format: "label CONTAINS %@", Self.title)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 60), "search found no \(Self.title)")
        result.tap()
        let rateButton = app.buttons.matching(NSPredicate(format: "label == 'Rate' OR label BEGINSWITH 'Your rating'")).firstMatch
        XCTAssertTrue(rateButton.waitForExistence(timeout: 30), "the detail never loaded")
        IOSTest.settle(1)
    }

    func testMakingAndSharingACardFromAMovie() {
        let app = enterDemo()
        openDetail(app)

        let more = app.navigationBars.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "the detail has no More button")
        more.tap()
        let share = app.buttons["Share Card"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 15), "the More menu has no Share Card")
        share.tap()

        let preview = IOSTest.element(app, "watchCard.preview")
        XCTAssertTrue(preview.waitForExistence(timeout: 30), "the card screen never opened")
        XCTAssertTrue(IOSTest.wait(for: preview, "label CONTAINS 'Low Tide'", timeout: 30), "the card never showed the movie")
        IOSTest.capture("01-card", in: self)

        let stars = IOSTest.element(app, "watchCard.stars")
        XCTAssertTrue(stars.waitForExistence(timeout: 10), "the card screen has no stars")
        stars.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        XCTAssertTrue(IOSTest.wait(for: preview, "label CONTAINS '4.5 out of 5 stars'", timeout: 10), "rating on the card screen did not put 4.5 stars on the card")

        let words = IOSTest.element(app, "watchCard.take")
        words.tap()
        words.typeText("Salt-stung and quietly devastating.\n")
        XCTAssertTrue(IOSTest.wait(for: preview, "label CONTAINS 'quietly devastating'", timeout: 10), "the words never reached the card")
        IOSTest.capture("02-words", in: self)

        app.segmentedControls.buttons["Story"].tap()
        IOSTest.element(app, "watchCard.style.paper").tap()
        IOSTest.settle(1)
        IOSTest.capture("03-story-paper", in: self)

        IOSTest.element(app, "watchCard.option.scores").tap()
        IOSTest.element(app, "watchCard.share").tap()
        let sheet = app.otherElements["ActivityListView"].firstMatch
        let copy = app.buttons["Copy"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15) || copy.waitForExistence(timeout: 5), "Share never opened the share sheet")
        IOSTest.capture("04-share-sheet", in: self)
    }
}
