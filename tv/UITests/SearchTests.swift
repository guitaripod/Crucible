import XCTest

/// Drives the Search tab through the real focus engine against the mock server.
///
/// Typing: once the system keyboard has focus (Select on the Search tab, then Down), `app.typeText`
/// types through the real keyboard, including `XCUIKeyboardKey.delete`; no grid navigation is needed.
/// `typeText` fails with "Neither element nor any descendant has keyboard focus" as soon as focus has
/// moved to the results or the tab bar, so go back to the keyboard first (`focusKeyboard`).
@MainActor
final class SearchTests: XCTestCase {
    private static let freshRecents = ["-recentSearches", "()"]

    override func setUp() {
        continueAfterFailure = true
    }

    func testIdleShelvesAndGenreGrid() {
        let app = launchSearch()
        TVTest.capture("01-idle-keyboard-focused", in: self)
        XCTAssertTrue(app.staticTexts["Browse Genres"].exists)
        XCTAssertTrue(app.staticTexts["Recently Added"].exists)
        XCTAssertFalse(app.staticTexts["Recent Searches"].exists)

        enterShelves(in: app)
        XCTAssertTrue(app.cells["Action"].hasFocus, "Down from the keyboard lands on the first genre")
        TVTest.capture("02-genre-focused", in: self)

        TVTest.remote.press(.right)
        TVTest.remote.press(.right)
        TVTest.settle(0.8)
        TVTest.capture("03-genre-focused-third", in: self)

        TVTest.remote.press(.down)
        TVTest.settle(1.2)
        XCTAssertTrue(focusedElement(in: app).elementType == .cell)
        TVTest.capture("04-recently-added-focused", in: self)

        TVTest.remote.press(.up)
        TVTest.settle(0.8)
        TVTest.remote.press(.select)
        TVTest.settle(2)
        TVTest.capture("05-genre-grid", in: self)

        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        TVTest.settle(1)
        TVTest.capture("06-genre-grid-scrolled", in: self)

        TVTest.remote.press(.menu)
        TVTest.settle(1.5)
        TVTest.capture("07-back-in-search", in: self)
        XCTAssertTrue(app.staticTexts["Browse Genres"].exists)
    }

    func testTypingShowsGroupedResultsAndScopeChips() {
        let app = launchSearch()
        type("hal", in: app)
        TVTest.settle(2)
        TVTest.capture("01-results-typing", in: self)
        XCTAssertTrue(app.buttons["tv.chip.scope.0"].exists)
        XCTAssertTrue(app.buttons["search.top.play"].exists)

        TVTest.remote.press(.down)
        TVTest.settle(1.2)
        TVTest.capture("02-results-focused", in: self)
        XCTAssertTrue(app.buttons["tv.chip.scope.0"].hasFocus || app.buttons["search.top.play"].hasFocus)

        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        TVTest.settle(1.2)
        TVTest.capture("03-results-movies-shelf", in: self)
        TVTest.remote.press(.down)
        TVTest.settle(1.2)
        TVTest.capture("04-results-shows-shelf", in: self)
        TVTest.remote.press(.down)
        TVTest.settle(1.2)
        TVTest.capture("05-results-episodes-shelf", in: self)
    }

    func testScopeChipsFilterWithoutANewSearch() {
        let app = launchSearch()
        type("hal", in: app)
        TVTest.settle(2)
        TVTest.remote.press(.down)
        TVTest.settle(1)
        XCTAssertTrue(app.buttons["tv.chip.scope.0"].hasFocus)
        for (index, name) in ["movies", "shows", "episodes"].enumerated() {
            TVTest.remote.press(.right)
            TVTest.settle(0.4)
            XCTAssertTrue(app.buttons["tv.chip.scope.\(index + 1)"].hasFocus, "focus on the \(name) chip")
            TVTest.remote.press(.select)
            TVTest.settle(1.5)
            TVTest.capture("0\(index + 1)-scope-\(name)", in: self)
        }
        TVTest.remote.press(.left)
        TVTest.remote.press(.left)
        TVTest.remote.press(.left)
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        TVTest.capture("04-scope-all-again", in: self)
    }

    func testNoResultsOffersAllScope() {
        let app = launchSearch()
        type("zzz", in: app)
        TVTest.settle(2)
        TVTest.capture("01-no-results", in: self)
        XCTAssertTrue(app.staticTexts["No results for \u{201C}zzz\u{201D}"].exists)
    }

    func testSearchFailureOffersTryAgain() {
        let app = launchSearch()
        setMock(failing: "search", on: true)
        type("hal", in: app)
        TVTest.settle(3)
        TVTest.capture("01-failed", in: self)
        XCTAssertTrue(app.staticTexts["Search Failed"].exists)
        let retry = app.buttons["Try Again"]
        XCTAssertTrue(retry.exists)

        setMock(failing: "search", on: false)
        TVTest.remote.press(.down)
        TVTest.settle(1)
        TVTest.capture("02-failed-try-again-focused", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(2.5)
        TVTest.capture("03-recovered", in: self)
        XCTAssertTrue(app.buttons["search.top.play"].exists)
    }

    func testTopResultPlayAndOpen() {
        let app = launchSearch()
        type("halcyon", in: app)
        TVTest.settle(2)
        TVTest.remote.press(.down)
        TVTest.settle(1)
        TVTest.remote.press(.down)
        TVTest.settle(0.8)
        XCTAssertTrue(app.buttons["search.top.play"].hasFocus)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.alerts["Halcyon"].waitForExistence(timeout: 5), "Play reaches the player seam")
        TVTest.capture("01-play-request", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(1)

        TVTest.remote.press(.right)
        TVTest.settle(0.5)
        XCTAssertTrue(app.buttons["search.top.open"].hasFocus)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.staticTexts["placeholder.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["placeholder.title"].label.hasPrefix("Detail"))
    }

    func testPlayPauseAndLongPressMenuOnAPoster() {
        let app = launchSearch()
        type("hal", in: app)
        TVTest.settle(2)
        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        TVTest.settle(1.2)
        TVTest.capture("01-poster-focused", in: self)
        TVTest.remote.press(.playPause)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "Play/Pause plays the focused title")
        TVTest.capture("02-play-pause-request", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(1)

        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1.2)
        TVTest.capture("03-context-menu", in: self)
        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        TVTest.settle(0.5)
        TVTest.capture("04-context-menu-mark-watched", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(1.2)
        TVTest.capture("05-marked-watched", in: self)

        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1.2)
        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        TVTest.remote.press(.select)
        TVTest.settle(1.2)
        TVTest.capture("06-marked-unwatched-again", in: self)
    }

    func testRecentSearchesAreSavedOnOpenAndCanBeReusedRemovedAndCleared() {
        var app = launchSearch(arguments: [])
        if clearRecentsIfShown(in: app) {
            app.terminate()
            app = launchSearch(arguments: [])
        }
        type("halcyon", in: app)
        TVTest.settle(2)
        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        TVTest.remote.press(.right)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.staticTexts["placeholder.title"].waitForExistence(timeout: 5))
        app.terminate()

        app = launchSearch(arguments: [])
        TVTest.settle(1)
        XCTAssertTrue(app.staticTexts["Recent Searches"].exists, "opening a result saved the query")
        TVTest.capture("01-recents-idle", in: self)
        enterShelves(in: app)
        TVTest.capture("02-recent-chip-focused", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(2.5)
        TVTest.capture("03-recent-reused", in: self)
        XCTAssertTrue(app.buttons["search.top.play"].exists)
        app.terminate()

        app = launchSearch(arguments: [])
        enterShelves(in: app)
        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1.2)
        TVTest.capture("04-recent-remove-menu", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(1)
        TVTest.capture("05-recent-removed", in: self)
        XCTAssertFalse(app.staticTexts["Recent Searches"].exists)
    }

    func testLightAppearance() {
        let app = launchSearch(extraEnvironment: ["CRUCIBLE_STYLE": "light"])
        TVTest.capture("01-idle-light", in: self)
        type("hal", in: app)
        TVTest.settle(2)
        TVTest.remote.press(.down)
        TVTest.settle(1.2)
        TVTest.capture("02-results-light", in: self)
        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        TVTest.settle(1.2)
        TVTest.capture("03-results-light-poster-focused", in: self)
    }

    func testGenreFailureOffersTryAgain() {
        let app = launchSearch()
        setMock(failing: "genre", on: true)
        enterShelves(in: app)
        TVTest.remote.press(.select)
        TVTest.settle(3)
        TVTest.capture("01-genre-failed", in: self)
        XCTAssertTrue(app.buttons["Try Again"].exists)
        setMock(failing: "genre", on: false)
        TVTest.remote.press(.select)
        TVTest.settle(3)
        TVTest.capture("02-genre-recovered", in: self)
        XCTAssertFalse(app.buttons["Try Again"].exists)
    }

    private func launchSearch(extraEnvironment: [String: String] = [:], arguments: [String] = freshRecents) -> XCUIApplication {
        setMock(failing: "search", on: false)
        setMock(failing: "genre", on: false)
        let app = TVTest.launch(extraEnvironment: extraEnvironment, arguments: arguments)
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30))
        TVTest.settle()
        let titles = tabBar.buttons.allElementsBoundByIndex.map(\.label)
        let index = titles.firstIndex(of: "Search") ?? titles.count - 2
        for _ in 0..<index { TVTest.remote.press(.right) }
        TVTest.remote.press(.select)
        TVTest.settle(2)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func type(_ text: String, in app: XCUIApplication) {
        focusKeyboard(in: app)
        app.typeText(text)
    }

    private func focusKeyboard(in app: XCUIApplication) {
        if app.keyboards.keys.matching(NSPredicate(format: "hasFocus == true")).count > 0 { return }
        TVTest.remote.press(.down)
        TVTest.settle(0.5)
    }

    private func enterShelves(in app: XCUIApplication) {
        focusKeyboard(in: app)
        TVTest.remote.press(.down)
        TVTest.settle(0.8)
    }

    /// Presses the Clear chip when recent searches are showing; returns whether it did.
    private func clearRecentsIfShown(in app: XCUIApplication) -> Bool {
        guard app.staticTexts["Recent Searches"].exists else { return false }
        enterShelves(in: app)
        for _ in 0..<9 { TVTest.remote.press(.right) }
        TVTest.remote.press(.select)
        TVTest.settle(1)
        return true
    }

    private func focusedElement(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    private func setMock(failing name: String, on: Bool) {
        guard let base = ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"],
              let url = URL(string: "\(base)/mock/fail?\(name)=\(on ? 1 : 0)")
        else { return }
        let done = expectation(description: "mock \(name)")
        URLSession.shared.dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }
}
