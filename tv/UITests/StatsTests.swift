import XCTest

/// Drives the Statistics screen through the real focus engine against the mock server. The mock's
/// history is generated relative to its start, so the numbers differ between runs; the tests assert
/// structure and state, and every step is captured for review. `CRUCIBLE_STATS_SCENARIO=empty` (with
/// `MOCK_NO_HISTORY=1` or `MOCK_HISTORY_ERROR=1` on the mock) runs the empty-state test instead.
@MainActor
final class StatsTests: XCTestCase {
    private static let sectionStops = 12

    override func setUp() {
        continueAfterFailure = false
    }

    private var scenario: String {
        ProcessInfo.processInfo.environment["CRUCIBLE_STATS_SCENARIO"] ?? "data"
    }

    private func openStatistics() -> XCUIApplication {
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_OPEN": "statistics"])
        XCTAssertTrue(app.collectionViews["stats.collection"].waitForExistence(timeout: 90))
        TVTest.settle(2)
        return app
    }

    /// The debug entry leaves focus on the tab bar; one Down lands on a chip, and Right walks to Year.
    private func focusYearChip(in app: XCUIApplication) {
        TVTest.remote.press(.down)
        for _ in 0..<4 {
            if app.buttons["stats.range.year"].hasFocus { return }
            TVTest.remote.press(.right)
        }
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "stats.range.year", timeout: 5))
    }

    func testEverySectionScrollsIntoView() throws {
        try XCTSkipUnless(scenario == "data")
        let app = openStatistics()
        focusYearChip(in: app)
        TVTest.settle(3)
        TVTest.capture("01-top", in: self)

        for stop in 1...Self.sectionStops {
            TVTest.remote.press(.down)
            TVTest.settle(1.4)
            TVTest.capture(String(format: "%02d-down-%d", stop + 1, stop), in: self)
        }
        for _ in 1...Self.sectionStops {
            TVTest.remote.press(.up)
        }
        TVTest.settle(1.2)
        XCTAssertTrue(app.buttons["stats.range.year"].exists)
        TVTest.capture("14-back-at-top", in: self)
    }

    func testRangeChipsAndLibraryMenu() throws {
        try XCTSkipUnless(scenario == "data")
        let app = openStatistics()
        focusYearChip(in: app)
        TVTest.settle(2.5)

        TVTest.remote.press(.right)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "stats.range.all"))
        TVTest.remote.press(.select)
        TVTest.settle(2.5)
        TVTest.capture("01-all-range", in: self)

        for _ in 0..<3 { TVTest.remote.press(.left) }
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "stats.range.week"))
        TVTest.remote.press(.select)
        TVTest.settle(2.5)
        TVTest.capture("02-week-range", in: self)

        for _ in 0..<4 { TVTest.remote.press(.right) }
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "stats.libraries"))
        TVTest.capture("03-libraries-focused", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        TVTest.capture("04-libraries-menu", in: self)

        TVTest.remote.press(.select)
        TVTest.settle(2.5)
        TVTest.capture("05-library-toggled", in: self)
        XCTAssertTrue(app.buttons["stats.libraries"].exists)

        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        TVTest.remote.press(.select)
        TVTest.settle(2.5)
        TVTest.capture("06-library-restored", in: self)
        XCTAssertTrue(app.buttons["stats.libraries"].exists)
    }

    func testPosterOpensItsDetail() throws {
        try XCTSkipUnless(scenario == "data")
        let app = openStatistics()
        focusYearChip(in: app)
        TVTest.settle(2)
        for _ in 0..<4 { TVTest.remote.press(.down) }
        TVTest.settle(1.5)
        TVTest.capture("01-top-show-focused", in: self)

        TVTest.remote.press(.select)
        XCTAssertTrue(app.staticTexts["placeholder.title"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["placeholder.title"].label.hasPrefix("Show"))
        TVTest.capture("02-detail-opened", in: self)
    }

    func testEmptyHistoryShowsAnExplanation() throws {
        try XCTSkipUnless(scenario == "empty")
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_OPEN": "statistics"])
        XCTAssertTrue(app.staticTexts["No watch history yet"].waitForExistence(timeout: 90))
        TVTest.settle(1)
        TVTest.capture("01-empty", in: self)
    }
}
