import XCTest

@MainActor
final class HistoryTests: XCTestCase {
    private static let rowPrefix = "history.row."
    private static let playPrefix = "history.play."

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        await MainActor.run { AppNavigation.setMockFlags("latency_ms=0") }
    }

    /// Launches the signed-in app, opens the You tab and selects Watch History, the way a user gets there.
    private func openHistory(mock: [String: String] = [:], extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = AppNavigation.launchHome(mock: mock, extraEnvironment: extraEnvironment)
        AppNavigation.selectTab("You", in: app)
        XCTAssertTrue(YouNavigation.row(app, "you.history").waitForExistence(timeout: 15))
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.history"))
        TVTest.remote.press(.select)
        return app
    }

    private func focusedIdentifier(_ app: XCUIApplication) -> String {
        AppNavigation.focusedIdentifier(app)
    }

    private func title(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["history.title"]
    }

    private func waitForFocusedRow(_ app: XCUIApplication, timeout: TimeInterval = 60) -> String {
        XCTAssertTrue(title(app).waitForExistence(timeout: timeout), "the History screen never appeared")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let identifier = focusedIdentifier(app)
            if identifier.hasPrefix(Self.rowPrefix) { return identifier }
            TVTest.settle(0.5)
        }
        return focusedIdentifier(app)
    }

    private func position(of identifier: String) -> Int? {
        identifier.split(separator: "-").last.flatMap { Int($0) }
    }

    private func ratingKey(ofFocusedPlayButton app: XCUIApplication) -> String {
        let identifier = focusedIdentifier(app)
        let trimmed = identifier.replacingOccurrences(of: Self.playPrefix, with: "")
        return trimmed.split(separator: "-").first.map(String.init) ?? ""
    }

    private func scrobble(_ ratingKey: String) {
        guard let base = ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"],
              let url = URL(string: "\(base)/:/scrobble?key=\(ratingKey)&identifier=com.plexapp.plugins.library") else { return }
        TVTest.fetch(url)
    }

    func testLoadedListFocusesTheFirstRowAndReachesThePlayButton() {
        let app = openHistory()
        let first = waitForFocusedRow(app)
        XCTAssertTrue(first.hasPrefix(Self.rowPrefix), "focus should start on the first row, was \(first)")
        XCTAssertEqual(position(of: first), 0)
        XCTAssertTrue(title(app).label.hasPrefix("Watch History"), title(app).label)
        XCTAssertTrue(title(app).label.contains("this week"), "the weekly summary belongs to the title: \(title(app).label)")
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

    func testChipsAndRefreshSitAboveTheListAndFilterIt() {
        let app = openHistory()
        _ = waitForFocusedRow(app)

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

    func testScrollingFocusPagesInMoreHistory() {
        let app = openHistory()
        _ = waitForFocusedRow(app)
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

    func testSelectOpensDetailAndMenuReturnsToTheSameRow() {
        let app = openHistory()
        _ = waitForFocusedRow(app)
        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        TVTest.settle(0.6)
        let row = focusedIdentifier(app)
        XCTAssertEqual(position(of: row), 2)

        TVTest.remote.press(.select)
        AppNavigation.expectDetail(app)
        TVTest.capture("11-select-opened-detail", in: self)

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: row, timeout: 15), "focus must return to \(row), not \(focusedIdentifier(app))")
        TVTest.capture("12-history-focus-restored", in: self)

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.history"), "Menu from History must return to the You list")
    }

    func testPlayAgainReachesThePlayerAndTheListReloadsWhenItIsDismissed() {
        let app = openHistory(extraEnvironment: ["CRUCIBLE_PLAYER_HOLD": "4"])
        _ = waitForFocusedRow(app)
        TVTest.remote.press(.down)
        TVTest.remote.press(.right)
        TVTest.settle(0.6)
        XCTAssertTrue(focusedIdentifier(app).hasPrefix(Self.playPrefix))
        let played = ratingKey(ofFocusedPlayButton: app)
        XCTAssertFalse(played.isEmpty)

        TVTest.remote.press(.select)
        XCTAssertTrue(app.otherElements["player.preroll"].waitForExistence(timeout: 60), "the play-again button must reach the player pre-roll")
        TVTest.capture("13-play-again-preroll", in: self)
        scrobble(played)
        XCTAssertTrue(app.otherElements["player.view"].waitForExistence(timeout: 60))
        TVTest.settle(2)

        AppNavigation.leavePlayer(app)
        TVTest.settle(2)
        let top = AppNavigation.element(app, "\(Self.rowPrefix)\(played)-0")
        XCTAssertTrue(top.waitForExistence(timeout: 20), "the play finished while the player was open must be the top row after it closes")
        XCTAssertFalse(focusedIdentifier(app).isEmpty)
        TVTest.capture("14-list-reloaded-after-the-player", in: self)
    }

    func testMenuWhileLoadingPopsBackToTheYouList() {
        let app = AppNavigation.launchHome()
        AppNavigation.selectTab("You", in: app)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.history"))
        AppNavigation.setMockFlags("latency_ms=6000")
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        TVTest.capture("15-loading", in: self)
        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.history", timeout: 10), "Menu while History loads must pop to the You list, focus is on \(focusedIdentifier(app))")
        TVTest.capture("16-popped-while-loading", in: self)
    }

    func testEmptyHistoryShowsTheEmptyState() {
        let app = openHistory(mock: ["MOCK_NO_HISTORY": "1"])
        XCTAssertTrue(app.staticTexts["No activity yet"].waitForExistence(timeout: 60))
        XCTAssertTrue(TVTest.waitForFocus(app.buttons["Refresh"], timeout: 10), "the state's button should hold focus, was \(focusedIdentifier(app))")
        TVTest.settle()
        TVTest.capture("17-empty", in: self)

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.history"))
    }

    func testFailedHistoryOffersTryAgainAndKeepsFocusOnTheScreen() {
        let app = openHistory(mock: ["MOCK_HISTORY_ERROR": "1"])
        XCTAssertTrue(app.staticTexts["Couldn't load history"].waitForExistence(timeout: 90))
        XCTAssertTrue(TVTest.waitForFocus(app.buttons["Try Again"], timeout: 10))
        TVTest.settle()
        TVTest.capture("18-error", in: self)

        TVTest.remote.press(.select)
        XCTAssertTrue(app.staticTexts["Couldn't load history"].waitForExistence(timeout: 90))
        TVTest.settle(2.0)
        TVTest.capture("19-error-after-retry", in: self)
        XCTAssertTrue(TVTest.waitForFocus(app.buttons["Try Again"], timeout: 10), "focus must stay on the screen after Try Again, was \(focusedIdentifier(app))")

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.history"), "Menu from the error state must pop")
    }
}
