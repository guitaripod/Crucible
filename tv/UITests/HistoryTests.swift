import XCTest

@MainActor
final class HistoryTests: XCTestCase {
    private static let rowPrefix = "history.row."
    private static let playPrefix = "history.play."

    override func setUp() {
        continueAfterFailure = false
    }

    private var mode: String {
        ProcessInfo.processInfo.environment["CRUCIBLE_HISTORY_MODE"] ?? "list"
    }

    private func launchHistory() -> XCUIApplication {
        TVTest.launch(extraEnvironment: ["CRUCIBLE_OPEN": "history"])
    }

    private func focusedIdentifier(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch.identifier
    }

    private func waitForFocusedRow(_ app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        guard app.staticTexts["history.title"].waitForExistence(timeout: timeout) else { return false }
        TVTest.settle(1.5)
        if !focusedIdentifier(app).hasPrefix(Self.rowPrefix) {
            TVTest.remote.press(.down)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if focusedIdentifier(app).hasPrefix(Self.rowPrefix) { return true }
            TVTest.settle(0.5)
        }
        return false
    }

    private func position(of identifier: String) -> Int? {
        identifier.split(separator: "-").last.flatMap { Int($0) }
    }

    func testLoadedListFocusesTheFirstRowAndReachesThePlayButton() throws {
        try XCTSkipUnless(mode == "list")
        let app = launchHistory()
        XCTAssertTrue(app.staticTexts["history.title"].waitForExistence(timeout: 60))
        XCTAssertTrue(waitForFocusedRow(app), "focus should start on the first row, was \(focusedIdentifier(app))")
        let first = focusedIdentifier(app)
        XCTAssertEqual(position(of: first), 0)
        TVTest.settle()
        TVTest.capture("01-loaded-first-row-focused", in: self)

        TVTest.remote.press(.right)
        TVTest.settle(0.6)
        XCTAssertTrue(focusedIdentifier(app).hasPrefix(Self.playPrefix), "Right should reach the play button")
        TVTest.capture("02-play-again-focused", in: self)

        TVTest.remote.press(.left)
        TVTest.settle(0.6)
        XCTAssertEqual(focusedIdentifier(app), first)

        TVTest.remote.press(.down)
        TVTest.settle(0.6)
        XCTAssertEqual(position(of: focusedIdentifier(app)), 1)
        TVTest.capture("03-second-row-focused", in: self)
    }

    func testChipsAndRefreshSitAboveTheListAndFilterIt() throws {
        try XCTSkipUnless(mode == "list")
        let app = launchHistory()
        XCTAssertTrue(waitForFocusedRow(app, timeout: 60))

        TVTest.remote.press(.up)
        TVTest.settle(0.6)
        var presses = 0
        while focusedIdentifier(app) != "tv.chip.all" && presses < 4 {
            TVTest.remote.press(.left)
            TVTest.settle(0.4)
            presses += 1
        }
        XCTAssertEqual(focusedIdentifier(app), "tv.chip.all")
        TVTest.capture("04-chips-focused", in: self)

        TVTest.remote.press(.right)
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        XCTAssertEqual(focusedIdentifier(app), "tv.chip.movies")
        TVTest.capture("05-movies-filter-applied", in: self)

        TVTest.remote.press(.right)
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        XCTAssertEqual(focusedIdentifier(app), "tv.chip.tv")
        TVTest.capture("06-tv-filter-applied", in: self)

        TVTest.remote.press(.right)
        TVTest.settle(0.6)
        XCTAssertEqual(focusedIdentifier(app), "tv.chip.refresh")
        TVTest.capture("07-refresh-focused", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(2.0)
        XCTAssertEqual(focusedIdentifier(app), "tv.chip.refresh")
        TVTest.capture("08-after-refresh", in: self)

        TVTest.remote.press(.down)
        TVTest.settle(0.8)
        XCTAssertTrue(focusedIdentifier(app).hasPrefix(Self.rowPrefix))
    }

    func testScrollingFocusPagesInMoreHistory() throws {
        try XCTSkipUnless(mode == "list")
        let app = launchHistory()
        XCTAssertTrue(waitForFocusedRow(app, timeout: 60))
        for _ in 0..<44 {
            TVTest.remote.press(.down)
        }
        TVTest.settle(2.0)
        TVTest.capture("09-scrolled-near-the-end-of-page-one", in: self)
        for _ in 0..<12 {
            TVTest.remote.press(.down)
        }
        TVTest.settle(2.0)
        let focused = focusedIdentifier(app)
        XCTAssertTrue(focused.hasPrefix(Self.rowPrefix))
        XCTAssertGreaterThanOrEqual(position(of: focused) ?? 0, 50, "rows past the first page of 50 mean the next page loaded")
        TVTest.capture("10-scrolled-into-page-two", in: self)
    }

    func testSelectOpensDetailAndPlayButtonStartsPlayback() throws {
        try XCTSkipUnless(mode == "list")
        let app = launchHistory()
        XCTAssertTrue(waitForFocusedRow(app, timeout: 60))

        TVTest.remote.press(.right)
        TVTest.settle(0.5)
        XCTAssertTrue(focusedIdentifier(app).hasPrefix(Self.playPrefix))
        TVTest.remote.press(.select)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "the play-again button should reach the player seam")
        TVTest.settle(0.5)
        TVTest.capture("11-play-again-reached-the-player", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        XCTAssertFalse(alert.exists)
        XCTAssertTrue(focusedIdentifier(app).hasPrefix(Self.playPrefix), "focus returns to the play button, was \(focusedIdentifier(app))")

        TVTest.remote.press(.left)
        TVTest.settle(0.8)
        XCTAssertTrue(focusedIdentifier(app).hasPrefix(Self.rowPrefix))
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        TVTest.capture("12-select-opened-detail", in: self)
        XCTAssertTrue(app.staticTexts["placeholder.title"].waitForExistence(timeout: 10), "Select should push the detail screen")
        XCTAssertTrue(app.staticTexts["placeholder.title"].label.hasPrefix("Detail "))
    }

    func testEmptyHistoryShowsTheEmptyState() throws {
        try XCTSkipUnless(mode == "empty")
        let app = launchHistory()
        XCTAssertTrue(app.staticTexts["No activity yet"].waitForExistence(timeout: 60))
        TVTest.settle(1.0)
        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "Refresh"))
        TVTest.settle()
        TVTest.capture("13-empty", in: self)
    }

    func testFailedHistoryOffersTryAgain() throws {
        try XCTSkipUnless(mode == "error")
        let app = launchHistory()
        XCTAssertTrue(app.staticTexts["Couldn't load history"].waitForExistence(timeout: 90))
        TVTest.settle(1.0)
        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "Try Again"))
        TVTest.settle()
        TVTest.capture("14-error", in: self)

        TVTest.remote.press(.select)
        TVTest.settle(0.3)
        TVTest.capture("15-error-retrying", in: self)
        XCTAssertTrue(app.staticTexts["Couldn't load history"].waitForExistence(timeout: 90))
        TVTest.settle(2.0)
        TVTest.capture("16-error-after-retry", in: self)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "Try Again"))
    }
}
