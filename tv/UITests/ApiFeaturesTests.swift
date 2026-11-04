import XCTest

/// The rest of what the Apple TV app does with the Plex API: a title's trailers, library filters beyond genre, searching for subtitles online,
/// the watchlist and playing a playlist from the remote.
@MainActor
final class ApiFeaturesTests: TVTestCase {
    private static let halcyon = "1001"
    private static let lowTide = "1003"

    private func capture(_ name: String) {
        TVTest.capture(name, in: self)
    }

    private func step(_ app: XCUIApplication, _ button: XCUIRemote.Button, until identifier: String, limit: Int = 14) {
        for _ in 0 ..< limit {
            if AppNavigation.focusedIdentifier(app).hasPrefix(identifier) { return }
            TVTest.remote.press(button)
            TVTest.settle(0.45)
        }
        XCTAssertTrue(AppNavigation.focusedIdentifier(app).hasPrefix(identifier), "focus never reached \(identifier), stopped on \(AppNavigation.focusedIdentifier(app))")
    }

    private func openDetail(_ ratingKey: String) -> XCUIApplication {
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_STYLE": "dark"])
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        TVTest.settle()
        let url = URL(string: "crucible://item/\(ratingKey)?type=movie")!
        Task { _ = await UIApplication.shared.open(url) }
        let prompt = XCUIApplication(bundleIdentifier: "com.apple.PineBoard").buttons["Open"]
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if app.buttons["detail.action.primary"].exists { break }
            if prompt.exists, prompt.hasFocus {
                TVTest.remote.press(.select)
                break
            }
            TVTest.settle(0.5)
        }
        TVTest.settle(0.5)
        XCTAssertTrue(app.buttons["detail.action.primary"].waitForExistence(timeout: 20), "detail never appeared")
        TVTest.settle(1.0)
        if !TVTest.waitForFocus(on: app, identifier: "detail.action.primary", timeout: 2) {
            TVTest.remote.press(.down)
        }
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.primary", timeout: 10), "primary action never took focus")
        return app
    }

    private func playerIsUp(_ app: XCUIApplication) -> Bool {
        app.otherElements["player.preroll"].waitForExistence(timeout: 60) || app.otherElements["player.view"].waitForExistence(timeout: 5)
    }

    func testATrailerPlaysFromTheExtrasShelf() {
        let app = openDetail(Self.halcyon)
        step(app, .down, until: "detail.extra.", limit: 6)
        capture("01-extras-focused")
        TVTest.remote.press(.select)
        XCTAssertTrue(playerIsUp(app), "Select on a trailer did not open the player")
        TVTest.settle(2)
        capture("02-trailer-playing")
    }

    func testTheFiltersMenuNarrowsTheLibrary() {
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_STYLE": "dark"])
        AppNavigation.selectTab("Movies", in: app)
        XCTAssertTrue(AppNavigation.element(app, "tv.library.filters").waitForExistence(timeout: 30), "the library header has no Filters button")
        TVTest.settle(1.5)
        TVTest.remote.press(.down)
        TVTest.settle(0.8)
        step(app, .up, until: "tv.chip.all", limit: 4)
        step(app, .right, until: "tv.library.filters", limit: 10)
        capture("01-filters-focused")
        TVTest.remote.press(.select)
        let decade = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Decade'")).firstMatch
        XCTAssertTrue(decade.waitForExistence(timeout: 10), "the Filters menu lists no Decade")
        TVTest.settle(0.8)
        capture("02-filters-menu")
        TVTest.remote.press(.select)
        TVTest.settle(0.8)
        TVTest.remote.press(.down)
        TVTest.remote.press(.select)
        TVTest.settle(2)
        let filtered = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Filtered'")).firstMatch
        XCTAssertTrue(filtered.waitForExistence(timeout: 20), "choosing a decade did not narrow the grid")
        capture("03-filtered")
    }

    func testSubtitlesAreSearchedOnlineFromTheMenu() {
        let app = openDetail(Self.lowTide)
        step(app, .right, until: "detail.action.subtitles", limit: 8)
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        capture("01-subtitles-menu")
        for _ in 0..<6 {
            TVTest.remote.press(.down)
            TVTest.settle(0.3)
        }
        TVTest.remote.press(.select)
        let candidate = app.alerts.firstMatch.buttons.matching(NSPredicate(format: "label CONTAINS 'OpenSubtitles'")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 20), "the search listed no subtitle")
        TVTest.settle(0.8)
        capture("02-subtitle-results")
        TVTest.remote.press(.select)
        XCTAssertTrue(IOSLikeWait.gone(app.alerts.firstMatch, timeout: 20), "the results stayed up after a choice")
        TVTest.settle(2)
        capture("03-after-download")
    }

    func testTheWatchlistListsTitlesAndExplainsMissingOnes() {
        let mock = ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"] ?? ""
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_STYLE": "dark", "CRUCIBLE_PLEXTV": mock])
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.watchlist")
        XCTAssertTrue(AppNavigation.element(app, "grid.1001").waitForExistence(timeout: 20), "the watchlist lists no title of the server's")
        let missing = AppNavigation.element(app, "grid.mock-night-train")
        XCTAssertTrue(missing.exists, "the watchlist lists no title the server lacks")
        TVTest.settle(1.0)
        capture("01-watchlist")
        step(app, .right, until: "grid.mock-night-train", limit: 4)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 20), "a title the server lacks explained nothing")
        capture("02-not-in-library")
    }

    func testAPlaylistPlaysWithPlayPause() {
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_STYLE": "dark"])
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.playlists")
        XCTAssertTrue(AppNavigation.firstElement(app, prefix: "grid.92").waitForExistence(timeout: 20), "Playlists lists nothing")
        TVTest.settle(1.0)
        TVTest.remote.press(.select)
        XCTAssertTrue(AppNavigation.firstElement(app, prefix: "grid.1006#").waitForExistence(timeout: 20), "the playlist lists none of its titles")
        TVTest.settle(1.0)
        TVTest.remote.press(.playPause)
        XCTAssertTrue(playerIsUp(app), "Play/Pause on a playlist entry did not open the player")
        capture("01-playlist-playing")
    }
}

private enum IOSLikeWait {
    static func gone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
