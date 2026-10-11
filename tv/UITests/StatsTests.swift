import XCTest

/// Drives the Statistics screen through the real focus engine against the mock server. The mock's
/// history is generated relative to its start, so the numbers differ between runs; the tests assert
/// structure and state, and every step is captured for review. Every launch starts from a fresh
/// install state (statistics mirror and library choices included) and states the mock it needs.
@MainActor
final class StatsTests: TVTestCase {
    private static let sectionStops = 12

    override func setUp() {
        continueAfterFailure = false
    }

    private func openStatistics(mock: [String: String] = [:], voiceOver: Bool = false) -> XCUIApplication {
        var environment = ["CRUCIBLE_OPEN": "statistics", "CRUCIBLE_FRESH": "1"]
        if voiceOver { environment["CRUCIBLE_VOICEOVER"] = "1" }
        return TVTest.launch(mock: mock, extraEnvironment: environment)
    }

    private func waitForContent(_ app: XCUIApplication) {
        XCTAssertTrue(app.collectionViews["stats.collection"].waitForExistence(timeout: 90), "the statistics page never appeared")
        TVTest.settle(2)
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

    func testEverySectionScrollsIntoView() {
        let app = openStatistics()
        waitForContent(app)
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

    func testRangeChipsAndLibraryMenu() {
        let app = openStatistics()
        waitForContent(app)
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
        XCTAssertTrue(app.buttons["stats.libraries"].label.contains("Filtered"), "the menu button should say the libraries are filtered")

        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        TVTest.remote.press(.select)
        TVTest.settle(2.5)
        TVTest.capture("06-library-restored", in: self)
        XCTAssertFalse(app.buttons["stats.libraries"].label.contains("Filtered"))
    }

    func testPosterOpensItsDetailAndMenuReturnsToIt() {
        let app = openStatistics()
        waitForContent(app)
        focusYearChip(in: app)
        TVTest.settle(2)
        for _ in 0..<4 { TVTest.remote.press(.down) }
        TVTest.settle(1.5)
        let posterLabel = AppNavigation.focusedElement(app).label
        XCTAssertFalse(posterLabel.isEmpty, "focus should rest on a poster")
        TVTest.capture("01-top-show-focused", in: self)

        TVTest.remote.press(.select)
        AppNavigation.expectDetail(app)
        TVTest.capture("02-detail-opened", in: self)

        TVTest.remote.press(.menu)
        XCTAssertTrue(app.collectionViews["stats.collection"].waitForExistence(timeout: 15))
        TVTest.settle(1.5)
        XCTAssertEqual(AppNavigation.focusedElement(app).label, posterLabel, "focus must return to the poster that was opened")
        TVTest.capture("03-focus-restored", in: self)
    }

    func testBingeCapsuleOpensItsShow() {
        let app = openStatistics()
        waitForContent(app)
        focusYearChip(in: app)
        TVTest.settle(2)
        var presses = 0
        while !AppNavigation.focusedElement(app).label.contains(" eps,") && presses < 16 {
            TVTest.remote.press(.down)
            TVTest.settle(0.6)
            presses += 1
        }
        XCTAssertTrue(AppNavigation.focusedElement(app).label.contains(" eps,"), "focus never reached a binge capsule")
        TVTest.capture("01-binge-focused", in: self)

        TVTest.remote.press(.select)
        AppNavigation.expectDetail(app)
        TVTest.capture("02-show-opened", in: self)
    }

    func testHeroReadsAsOneStopForVoiceOver() {
        let app = openStatistics(voiceOver: true)
        waitForContent(app)
        focusYearChip(in: app)
        TVTest.remote.press(.down)
        TVTest.settle(1.5)
        let label = AppNavigation.focusedElement(app).label
        XCTAssertTrue(label.contains("hours") || label.contains("plays"), "the hero should be reachable and read its headline number, not \(label)")
        TVTest.capture("01-hero-focused", in: self)
    }

    func testMenuPopsWhileTheFirstLoadRuns() {
        let app = AppNavigation.launchHome(
            mock: ["MOCK_SLOW_HISTORY_SECTIONS": "all", "MOCK_SLOW_HISTORY_MS": "25000"],
            extraEnvironment: ["CRUCIBLE_FRESH": "1"]
        )
        AppNavigation.selectTab("You", in: app)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.history"))
        YouNavigation.openRow(app, "you.statistics")
        XCTAssertTrue(app.staticTexts["Building your statistics"].waitForExistence(timeout: 30), "the first load should show the loading state")
        TVTest.settle(1)
        TVTest.capture("01-loading", in: self)

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.statistics"), "Menu while Statistics loads must pop back to the You list, not leave the app")
        TVTest.capture("02-popped-to-you", in: self)
    }

    func testEmptyHistoryShowsAnExplanation() {
        let app = openStatistics(mock: ["MOCK_NO_HISTORY": "1"])
        XCTAssertTrue(app.staticTexts["No watch history yet"].waitForExistence(timeout: 90))
        TVTest.settle(1)
        TVTest.capture("01-empty", in: self)
    }

    func testFailingHistoryEndsInTheEmptyExplanationNotAnEndlessSpinner() {
        let app = openStatistics(mock: ["MOCK_HISTORY_ERROR": "1"])
        XCTAssertTrue(app.staticTexts["No watch history yet"].waitForExistence(timeout: 90))
        TVTest.settle(1)
        TVTest.capture("01-failed-sync", in: self)
    }
}
