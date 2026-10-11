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

    func testMenuPopsWhileAGenreLoads() {
        let app = launchSearch()
        TVTest.configureMock(["MOCK_LATENCY_MS": "8000"])
        enterShelves(in: app)
        XCTAssertTrue(app.cells["Action"].hasFocus)
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        TVTest.capture("01-genre-loading", in: self)
        XCTAssertFalse(app.cells["Action"].exists, "the genre screen replaced Search while it loads")
        TVTest.remote.press(.menu)
        TVTest.settle(1.5)
        TVTest.capture("02-popped", in: self)
        XCTAssertEqual(app.state, .runningForeground, "Menu while loading must not leave the app")
        XCTAssertTrue(waitForFocus(of: app.cells["Action"]), "Menu while loading popped back to Search with the genre focused")
        TVTest.configureMock()
    }

    func testSelectingAGenreTilePushesExactlyOneScreen() {
        let app = launchSearch()
        enterShelves(in: app)
        XCTAssertTrue(app.cells["Action"].hasFocus)
        TVTest.remote.press(.select)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'titles'")).firstMatch.waitForExistence(timeout: 20))
        TVTest.settle(1)
        TVTest.remote.press(.menu)
        XCTAssertTrue(app.cells["Action"].waitForExistence(timeout: 10), "one Menu returns to Search, so Select pushed one genre screen")
        XCTAssertTrue(waitForFocus(of: app.cells["Action"]))
    }

    func testSelectingTheOpenButtonPushesExactlyOneScreen() {
        let app = launchSearch()
        type("halcyon", in: app)
        TVTest.settle(2)
        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        TVTest.remote.press(.right)
        XCTAssertTrue(app.buttons["search.top.open"].hasFocus)
        TVTest.remote.press(.select)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.buttons["detail.action.primary"].waitForExistence(timeout: 20))
        TVTest.settle(1)
        TVTest.remote.press(.menu)
        XCTAssertTrue(app.buttons["search.top.open"].waitForExistence(timeout: 10), "one Menu returns to the results, so Open pushed one detail screen")
    }

    func testTheGenreGridReadsPagesAsFocusNearsTheEnd() throws {
        let app = launchSearch(mock: ["MOCK_LIBRARY_PAD": "600"])
        enterShelves(in: app)
        let before = try moviePageRequests(startingAt: 50)
        TVTest.remote.press(.select)
        let count = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'titles'")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 20))
        TVTest.settle(1.5)
        TVTest.capture("01-first-page", in: self)
        XCTAssertEqual(try moviePageRequests(startingAt: 50) - before, 0, "the first paint reads the first page only, not the whole genre")
        for _ in 0..<12 {
            TVTest.remote.press(.down)
        }
        TVTest.settle(2)
        TVTest.capture("02-after-scrolling", in: self)
        XCTAssertGreaterThan(try moviePageRequests(startingAt: 50) - before, 0, "scrolling down reads the next page")
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
        let app = launchSearch(mock: ["MOCK_FAIL_SEARCH": "1"])
        type("hal", in: app)
        TVTest.settle(3)
        TVTest.capture("01-failed", in: self)
        XCTAssertTrue(app.staticTexts["Search Failed"].exists)
        XCTAssertTrue(app.buttons["Try Again"].exists)

        TVTest.configureMock()
        TVTest.remote.press(.down)
        TVTest.settle(1)
        TVTest.capture("02-failed-try-again-focused", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(2.5)
        TVTest.capture("03-recovered", in: self)
        XCTAssertTrue(app.buttons["search.top.play"].exists)
    }

    func testTopResultPlayAndOpen() {
        let app = launchSearch(extraEnvironment: ["CRUCIBLE_PLAYER_HOLD": "6"])
        type("halcyon", in: app)
        TVTest.settle(2)
        TVTest.remote.press(.down)
        TVTest.settle(1)
        TVTest.remote.press(.down)
        TVTest.settle(0.8)
        XCTAssertTrue(app.buttons["search.top.play"].hasFocus)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.otherElements["player.preroll"].waitForExistence(timeout: 20), "Play opens the player")
        TVTest.capture("01-play-preroll", in: self)
        leavePlayer(in: app, until: app.buttons["search.top.play"])

        TVTest.remote.press(.right)
        TVTest.settle(0.5)
        XCTAssertTrue(app.buttons["search.top.open"].hasFocus)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.buttons["detail.action.primary"].waitForExistence(timeout: 20), "Open Movie shows the detail screen")
        TVTest.capture("02-detail", in: self)
        TVTest.remote.press(.menu)
        XCTAssertTrue(app.buttons["search.top.open"].waitForExistence(timeout: 10), "Back from the detail returns to the results")
        TVTest.settle(1)
        XCTAssertTrue(app.buttons["search.top.play"].hasFocus || app.buttons["search.top.open"].hasFocus, "and focus rests on the top result")
    }

    func testPlayPauseStartsPlaybackAndTheLongPressMenuMarksWatched() {
        let app = launchSearch(extraEnvironment: ["CRUCIBLE_PLAYER_HOLD": "6"])
        type("hal", in: app)
        TVTest.settle(2)
        focusFirstPoster(in: app)
        TVTest.capture("01-poster-focused", in: self)
        XCTAssertEqual(focusedElement(in: app).value as? String, "Unwatched", "the chosen poster starts unwatched")

        TVTest.remote.press(.playPause)
        XCTAssertTrue(app.otherElements["player.preroll"].waitForExistence(timeout: 20), "Play/Pause plays the focused title")
        TVTest.capture("02-play-pause-preroll", in: self)
        leavePlayer(in: app, until: app.buttons["search.top.play"])

        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1.2)
        TVTest.capture("03-context-menu", in: self)
        TVTest.remote.press(.down)
        TVTest.settle(0.5)
        TVTest.capture("04-context-menu-mark-watched", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(1.2)
        XCTAssertEqual(focusedElement(in: app).value as? String, "Watched")
        TVTest.capture("05-marked-watched", in: self)

        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1.2)
        TVTest.remote.press(.down)
        TVTest.remote.press(.select)
        TVTest.settle(1.2)
        XCTAssertEqual(focusedElement(in: app).value as? String, "Unwatched")
        TVTest.capture("06-marked-unwatched-again", in: self)
    }

    func testAFailedWatchedMarkRollsBackAndTellsTheViewer() {
        let app = launchSearch(mock: ["MOCK_FAIL_WATCHED": "1"])
        type("hal", in: app)
        TVTest.settle(2)
        focusFirstPoster(in: app)
        XCTAssertEqual(focusedElement(in: app).value as? String, "Unwatched")

        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1)
        TVTest.remote.press(.down)
        TVTest.remote.press(.select)
        let alert = app.alerts["Couldn\u{2019}t Mark Watched"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "a refused mark must be reported")
        TVTest.capture("01-failure-alert", in: self)
        TVTest.remote.press(.menu)
        XCTAssertTrue(waitForDisappearance(of: alert), "Menu dismisses the alert")
        TVTest.settle(0.8)
        XCTAssertEqual(focusedElement(in: app).value as? String, "Unwatched", "the card goes back to what the server says")
        TVTest.capture("02-rolled-back", in: self)
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
        XCTAssertTrue(app.buttons["detail.action.primary"].waitForExistence(timeout: 20))
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
        let app = launchSearch(mock: ["MOCK_FAIL_GENRE": "1"])
        enterShelves(in: app)
        TVTest.remote.press(.select)
        TVTest.settle(1)
        TVTest.capture("01-genre-failed", in: self)
        XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 15))
        TVTest.configureMock()
        TVTest.remote.press(.select)
        TVTest.settle(3)
        TVTest.capture("02-genre-recovered", in: self)
        XCTAssertFalse(app.buttons["Try Again"].exists)
    }

    private func launchSearch(
        mock: [String: String] = [:],
        extraEnvironment: [String: String] = [:],
        arguments: [String] = freshRecents
    ) -> XCUIApplication {
        let app = TVTest.launch(mock: mock, extraEnvironment: extraEnvironment, arguments: arguments)
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 90), "the main UI never appeared")
        TVTest.settle()
        let titles = tabBar.buttons.allElementsBoundByIndex.map(\.label)
        let index = max(0, titles.firstIndex(of: "Search") ?? titles.count - 2)
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

    /// Moves focus from the keyboard to the first poster of the results: scope chip, top result, poster.
    private func focusFirstPoster(in app: XCUIApplication) {
        for _ in 0..<3 { TVTest.remote.press(.down) }
        TVTest.settle(1.2)
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

    /// Menu until Search's own screen is back (the pre-roll and the player take a few presses).
    private func leavePlayer(in app: XCUIApplication, until screen: XCUIElement) {
        for _ in 0..<6 where !screen.exists {
            TVTest.remote.press(.menu)
            TVTest.settle(2)
        }
        XCTAssertTrue(screen.waitForExistence(timeout: 15), "Menu leaves the player and returns to Search")
    }

    private func focusedElement(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    private func waitForFocus(of element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "hasFocus == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    private nonisolated static var mock: URL {
        URL(string: ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"] ?? "http://127.0.0.1:32467")!
    }

    /// How many requests for the Movies library listing starting at `offset` the mock has seen.
    private func moviePageRequests(startingAt offset: Int) throws -> Int {
        var components = try XCTUnwrap(URLComponents(string: Self.mock.absoluteString + "/mock/requests"))
        components.queryItems = [URLQueryItem(name: "contains", value: "/library/sections/1/all?X-Plex-Container-Start=\(offset)&")]
        let data = try XCTUnwrap(TVTest.fetch(try XCTUnwrap(components.url)))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Int]
        return try XCTUnwrap(object?["count"])
    }
}
