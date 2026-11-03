import XCTest

/// Rates a title in the built-in demo through the star sheet: tapping the star button, picking half and whole steps along the row, clearing
/// the rating, and the rating's trip to the server and back (the demo library keeps it). Runs on the iPhone and the iPad.
@MainActor
final class RatingTests: XCTestCase {
    private static let title = "Cold Meridian"

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
        XCTAssertTrue(rateButton.waitForExistence(timeout: 30), "the detail has no Rate button")
        IOSTest.settle(1)
        if rateButton.label != "Rate" { clearRating(app, rateButton) }
    }

    /// The demo library keeps ratings between launches, so a title rated by an earlier run starts out unrated here.
    private func clearRating(_ app: XCUIApplication, _ rateButton: XCUIElement) {
        rateButton.tap()
        let clear = app.buttons["Clear Rating"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10), "a rated title offers no Clear Rating")
        clear.tap()
        XCTAssertTrue(app.buttons["Rate"].waitForExistence(timeout: 10), "clearing did not return the Rate button")
        IOSTest.settle(1)
    }

    private func stars(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "Your Rating").firstMatch
    }

    func testRatingATitleKeepsHalfStepsAndClears() {
        let app = enterDemo()
        openDetail(app)
        IOSTest.capture("01-detail-unrated", in: self)

        app.buttons["Rate"].tap()
        let row = stars(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the rating sheet never showed its stars")
        XCTAssertEqual(row.value as? String, "Not rated")
        IOSTest.capture("02-sheet-unrated", in: self)

        row.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).tap()
        IOSTest.settle(0.2)
        IOSTest.capture("03-sheet-rated", in: self)
        XCTAssertTrue(app.buttons["Your rating, 3.5 out of 5 stars"].waitForExistence(timeout: 10), "a tap at 65% did not rate 3.5 stars")
        IOSTest.capture("04-detail-rated", in: self)

        app.buttons["Your rating, 3.5 out of 5 stars"].tap()
        let again = stars(app)
        XCTAssertTrue(again.waitForExistence(timeout: 10), "the sheet did not reopen")
        XCTAssertEqual(again.value as? String, "3.5 out of 5 stars")
        IOSTest.capture("04b-sheet-reopened", in: self)
        again.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Your rating, 5 out of 5 stars"].waitForExistence(timeout: 10), "a tap at the end did not rate 5 stars")

        app.buttons["Your rating, 5 out of 5 stars"].tap()
        let clear = app.buttons["Clear Rating"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10), "a rated title offers no Clear Rating")
        clear.tap()
        XCTAssertTrue(app.buttons["Rate"].waitForExistence(timeout: 10), "clearing did not return the Rate button")
        IOSTest.capture("05-detail-cleared", in: self)
    }

    func testTheRatingSurvivesLeavingAndReturning() {
        let app = enterDemo()
        openDetail(app)
        app.buttons["Rate"].tap()
        let row = stars(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Your rating, 2.5 out of 5 stars"].waitForExistence(timeout: 10))
        IOSTest.settle(1)

        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        IOSTest.settle(1)
        let result = app.cells.containing(NSPredicate(format: "label CONTAINS %@", Self.title)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        result.tap()
        XCTAssertTrue(app.buttons["Your rating, 2.5 out of 5 stars"].waitForExistence(timeout: 30), "the saved rating was gone after reopening")
        IOSTest.capture("01-reopened", in: self)
    }
}
