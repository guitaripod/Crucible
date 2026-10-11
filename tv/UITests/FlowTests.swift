import XCTest

/// The journeys that cross feature boundaries: open a title from every entry point, come back with
/// the focus where it was, and walk the You tab down and up again. Each test drives the real focus
/// engine and captures every step for review.
@MainActor
final class FlowTests: TVTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        await MainActor.run { AppNavigation.setMockFlags("latency_ms=0") }
    }

    private func capture(_ name: String) {
        TVTest.settle(0.8)
        TVTest.capture(name, in: self)
    }

    /// Selects the You tab; selecting it hands focus to its first row.
    private func enterYouTab(_ app: XCUIApplication) {
        AppNavigation.selectTab("You", in: app)
        XCTAssertTrue(YouNavigation.row(app, "you.history").waitForExistence(timeout: 15))
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.history"))
        TVTest.settle()
    }

    private func waitForFocusedRow(_ app: XCUIApplication, prefix: String, timeout: TimeInterval = 30) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let identifier = AppNavigation.focusedIdentifier(app)
            if identifier.hasPrefix(prefix) { return identifier }
            TVTest.settle(0.5)
        }
        return AppNavigation.focusedIdentifier(app)
    }

    func testHomeDetailPlayAndBackWithFocusOnTheSameCard() {
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_PLAYER_HOLD": "4"])
        XCTAssertTrue(AppNavigation.move(app, .down, untilFocusHasPrefix: "\(AppNavigation.homeCardPrefix)recentlyAdded."), "focus never reached Recently Added: \(AppNavigation.focusedIdentifier(app))")
        let card = AppNavigation.focusedIdentifier(app)
        capture("01-home-card-focused")

        TVTest.remote.press(.select)
        AppNavigation.expectDetail(app)
        capture("02-detail")

        TVTest.remote.press(.select)
        XCTAssertTrue(app.otherElements["player.preroll"].waitForExistence(timeout: 60), "Play must reach the player pre-roll")
        TVTest.capture("03-preroll", in: self)
        XCTAssertTrue(app.otherElements["player.view"].waitForExistence(timeout: 60))
        TVTest.settle(2)
        TVTest.capture("04-playing", in: self)

        AppNavigation.leavePlayer(app)
        AppNavigation.expectDetail(app)
        capture("05-detail-after-player")

        TVTest.remote.press(.menu)
        XCTAssertTrue(AppNavigation.element(app, card).waitForExistence(timeout: 15), "Menu from Detail must land on Home")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: card), "focus must return to \(card), not \(AppNavigation.focusedIdentifier(app))")
        capture("06-home-focus-restored")
    }

    func testLibraryPosterOpensDetailAndMenuReturnsToIt() {
        let app = AppNavigation.launchHome()
        AppNavigation.selectTab("Movies", in: app)
        XCTAssertTrue(AppNavigation.firstElement(app, prefix: "tv.library.media.").waitForExistence(timeout: 30), "no library poster appeared")
        TVTest.settle(1.0)
        TVTest.remote.press(.down)
        XCTAssertTrue(AppNavigation.move(app, .down, untilFocusHasPrefix: "tv.library.media."), "focus never reached a poster: \(AppNavigation.focusedIdentifier(app))")
        let poster = AppNavigation.focusedIdentifier(app)
        capture("01-library-poster-focused")

        TVTest.remote.press(.select)
        AppNavigation.expectDetail(app)
        capture("02-detail")

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: poster), "focus must return to \(poster), not \(AppNavigation.focusedIdentifier(app))")
        capture("03-library-focus-restored")
    }

    private func openSearch(typing text: String) -> XCUIApplication {
        let app = AppNavigation.launchHome(arguments: ["-recentSearches", "()"])
        AppNavigation.selectTab("Search", in: app)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 20))
        TVTest.settle(1.5)
        TVTest.remote.press(.down)
        TVTest.settle(0.5)
        app.typeText(text)
        TVTest.settle(2)
        return app
    }

    func testSearchResultPosterOpensDetailAndMenuReturnsToIt() {
        let app = openSearch(typing: "hal")
        capture("01-results")
        for _ in 0..<3 { TVTest.remote.press(.down) }
        TVTest.settle(1.2)
        let focused = AppNavigation.focusedElement(app)
        let poster = focused.label
        XCTAssertFalse(poster.isEmpty || focused.identifier.hasPrefix("search.top."), "focus should rest on a result poster, not on \(focused.identifier)")
        capture("02-poster-focused")

        TVTest.remote.press(.select)
        AppNavigation.expectDetail(app)
        capture("03-detail")

        TVTest.remote.press(.menu)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 15))
        TVTest.settle(1.5)
        XCTAssertEqual(AppNavigation.focusedElement(app).label, poster, "focus must return to the poster that was opened")
        capture("04-results-focus-restored")
    }

    func testTopResultDetailsOpensDetailAndMenuReturnsToTheTopResult() {
        let app = openSearch(typing: "halcyon")
        TVTest.remote.press(.down)
        TVTest.settle(1)
        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "search.top.play"), "focus is on \(AppNavigation.focusedIdentifier(app))")
        TVTest.remote.press(.right)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "search.top.open"))
        capture("01-top-result-details-focused")

        TVTest.remote.press(.select)
        AppNavigation.expectDetail(app)
        XCTAssertTrue(AppNavigation.detailPrimary(app).label.contains("Halcyon"), AppNavigation.detailPrimary(app).label)
        capture("02-detail")

        TVTest.remote.press(.menu)
        XCTAssertTrue(AppNavigation.element(app, "search.top.open").waitForExistence(timeout: 15))
        TVTest.settle(1.5)
        let landed = AppNavigation.focusedIdentifier(app)
        XCTAssertTrue(landed.hasPrefix("search.top."), "focus must return to the top result, not \(landed)")
        capture("03-results-focus-restored")
    }

    func testHistoryRowOpensDetailAndMenuReturnsToIt() {
        let app = AppNavigation.launchHome()
        enterYouTab(app)
        YouNavigation.openRow(app, "you.history")
        XCTAssertTrue(app.descendants(matching: .any)["history.title"].waitForExistence(timeout: 60))
        TVTest.settle(1.5)
        if !AppNavigation.focusedIdentifier(app).hasPrefix("history.row.") { TVTest.remote.press(.down) }
        let row = waitForFocusedRow(app, prefix: "history.row.")
        XCTAssertTrue(row.hasPrefix("history.row."), "focus is on \(row)")
        capture("01-history-row-focused")

        TVTest.remote.press(.select)
        AppNavigation.expectDetail(app)
        capture("02-detail")

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: row), "focus must return to \(row), not \(AppNavigation.focusedIdentifier(app))")
        capture("03-history-focus-restored")

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.history"), "Menu from History must return to the You list")
    }

    func testStatisticsPosterOpensDetailAndMenuReturnsToIt() {
        let app = AppNavigation.launchHome()
        enterYouTab(app)
        YouNavigation.openRow(app, "you.statistics")
        XCTAssertTrue(app.collectionViews["stats.collection"].waitForExistence(timeout: 90))
        TVTest.settle(2)
        if !AppNavigation.focusedIdentifier(app).hasPrefix("stats.range.") {
            TVTest.remote.press(.down)
        }
        TVTest.settle(2)
        for _ in 0..<4 { TVTest.remote.press(.down) }
        TVTest.settle(1.5)
        let posterLabel = AppNavigation.focusedElement(app).label
        XCTAssertFalse(posterLabel.isEmpty, "focus should rest on a poster")
        capture("01-poster-focused")

        TVTest.remote.press(.select)
        AppNavigation.expectDetail(app)
        capture("02-detail")

        TVTest.remote.press(.menu)
        XCTAssertTrue(app.collectionViews["stats.collection"].waitForExistence(timeout: 15))
        TVTest.settle(1.5)
        XCTAssertEqual(AppNavigation.focusedElement(app).label, posterLabel, "focus must return to the poster that was opened")
        capture("03-statistics-focus-restored")

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.statistics"), "Menu from Statistics must return to the You list")
    }

    func testYouSettingsSubScreenAndTwoMenusBack() {
        let app = AppNavigation.launchHome()
        enterYouTab(app)
        capture("01-you")

        YouNavigation.openRow(app, "you.server")
        XCTAssertTrue(YouNavigation.row(app, "server.test").waitForExistence(timeout: 20))
        TVTest.settle(1.5)
        capture("02-server")

        YouNavigation.openRow(app, "server.addServer")
        XCTAssertTrue(app.textFields["addServer.address"].waitForExistence(timeout: 15))
        TVTest.settle(1.0)
        capture("03-add-server")

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "server.addServer"), "the first Menu returns to Server with focus on Add Server")
        capture("04-back-on-server")

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.server"), "the second Menu returns to the You list with focus on Server")
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        capture("05-back-on-you")
    }

    func testDeepLinkFromAnotherTabOpensDetailOnHomeAndKeepsTheOtherTab() {
        let app = AppNavigation.launchHome()
        enterYouTab(app)
        YouNavigation.openRow(app, "you.server")
        XCTAssertTrue(YouNavigation.row(app, "server.test").waitForExistence(timeout: 20))
        capture("01-deep-in-you")

        AppNavigation.openFromOutside("crucible://item/1001?type=movie", in: self)
        XCTAssertTrue(AppNavigation.detailPrimary(app).waitForExistence(timeout: 30), "the link must open the Detail")
        TVTest.settle(1.5)
        XCTAssertTrue(AppNavigation.detailPrimary(app).label.contains("Halcyon"), AppNavigation.detailPrimary(app).label)
        capture("02-detail-on-home")

        AppNavigation.expectHomeUnderDetail(app)
        capture("03-home")

        AppNavigation.selectTab("You", in: app)
        XCTAssertTrue(YouNavigation.row(app, "server.test").waitForExistence(timeout: 15), "the You tab keeps the screen it was left on")
        capture("04-you-kept-its-screen")
    }
}
