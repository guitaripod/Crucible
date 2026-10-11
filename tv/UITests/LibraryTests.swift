import XCTest

/// Drives the Library tabs through the real focus engine against the mock Plex server. Run the mock with
/// `MOCK_LIBRARY_PAD=150 MOCK_FAIL_SECTIONS=3 MOCK_SLOW_HISTORY_SECTIONS=2 MOCK_SLOW_HISTORY_MS=9000`: Movies
/// grows to 150 items so pagination and the A-Z jump have something to do, Documentaries fails to load and
/// the TV Shows watch history answers after nine seconds. The other libraries keep their default content;
/// Anime is empty.
@MainActor
final class LibraryTests: XCTestCase {
    private static let mediaPrefix = "tv.library.media."
    private static let recentPrefix = "tv.library.recent."
    private static let railPrefix = "tv.library.rail."

    override func setUp() {
        continueAfterFailure = false
    }

    func testMovieLibraryLoadedFiltersAndMenus() {
        let app = openTab("Movies")
        waitForRecents(in: app)
        enterContent(app)
        TVTest.settle(1.0)
        TVTest.capture("01-loaded-first-recent-focused", in: self)
        XCTAssertTrue(focusedIdentifier(app).hasPrefix(Self.recentPrefix), "initial focus should land on the first Recently Watched poster")

        step(app, .up, until: "tv.library.chip.all")
        TVTest.capture("02-all-chip-focused", in: self)

        TVTest.remote.press(.right)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "tv.library.chip.unwatched"))
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        XCTAssertEqual(count(app, prefix: Self.recentPrefix), 0, "Recently Watched hides while a filter is active")
        TVTest.capture("03-unwatched-selected", in: self)

        step(app, .right, until: "tv.library.genre", limit: 3)
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        TVTest.capture("04-genre-menu-open", in: self)
        TVTest.remote.press(.down)
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        TVTest.capture("05-genre-chosen-over-unwatched", in: self)

        step(app, .right, until: "tv.library.sort")
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        TVTest.capture("06-sort-menu-open", in: self)
        TVTest.remote.press(.down)
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        TVTest.capture("07-sorted-by-year", in: self)

        step(app, .left, until: "tv.library.chip.all", limit: 6)
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        TVTest.capture("08-filters-cleared-sort-kept", in: self)
    }

    func testChipsLeadDownIntoTheShelfAndTheGridAndBackUp() {
        let app = openTab("Movies")
        waitForRecents(in: app)
        enterContent(app)

        step(app, .up, until: "tv.library.chip.all")
        TVTest.remote.press(.down)
        TVTest.settle(0.8)
        TVTest.capture("26-down-from-all-chip", in: self)
        XCTAssertTrue(focusedIdentifier(app).hasPrefix(Self.recentPrefix), "Down from the All chip should reach the Recently Watched shelf, got \(focusedIdentifier(app))")

        TVTest.remote.press(.up)
        TVTest.settle(0.8)
        XCTAssertTrue(focusedIdentifier(app).hasPrefix("tv.library.chip."), "Up from the shelf should return to the chips, got \(focusedIdentifier(app))")

        for identifier in ["tv.library.genre", "tv.library.sort", "tv.library.folders"] {
            step(app, .right, until: identifier, limit: 8)
            TVTest.remote.press(.down)
            TVTest.settle(0.8)
            let landed = focusedIdentifier(app)
            XCTAssertTrue(landed.hasPrefix(Self.recentPrefix) || landed.hasPrefix(Self.mediaPrefix), "Down from \(identifier) should leave the header, got \(landed)")
            TVTest.remote.press(.up)
            TVTest.settle(0.8)
            XCTAssertTrue(focusedIdentifier(app).hasPrefix("tv.library.chip.") || focusedIdentifier(app).hasPrefix("tv.library.genre") || focusedIdentifier(app).hasPrefix("tv.library.sort") || focusedIdentifier(app).hasPrefix("tv.library.folders"), "Up should return to the header, got \(focusedIdentifier(app))")
        }

        step(app, .right, until: "tv.library.chip.unwatched", limit: 8)
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        XCTAssertEqual(count(app, prefix: Self.recentPrefix), 0)
        TVTest.remote.press(.down)
        TVTest.settle(0.8)
        TVTest.capture("27-down-from-chip-into-filtered-grid", in: self)
        XCTAssertTrue(focusedIdentifier(app).hasPrefix(Self.mediaPrefix), "Down from a chip should reach the first poster of the filtered grid, got \(focusedIdentifier(app))")
        TVTest.remote.press(.up)
        TVTest.settle(0.8)
        TVTest.capture("28-up-from-first-row-back-to-chips", in: self)
        XCTAssertTrue(focusedIdentifier(app).hasPrefix("tv.library.chip."), "Up from the first row should return to the chips, got \(focusedIdentifier(app))")
    }

    func testSlowHistoryDoesNotHoldBackTheGridAndTheShelfJoinsWithoutMovingFocus() {
        let app = openTab("TV Shows")
        waitForPosters(in: app)
        XCTAssertEqual(count(app, prefix: Self.recentPrefix), 0, "the grid should appear before the slow history answers")
        enterContent(app)
        let focused = focusedIdentifier(app)
        XCTAssertTrue(focused.hasPrefix(Self.mediaPrefix), "without a shelf the first poster of the grid takes the focus, got \(focused)")
        TVTest.capture("29-grid-before-slow-history", in: self)

        TVTest.settle(10)
        XCTAssertEqual(focusedIdentifier(app), focused, "a shelf arriving late must not move the focus")
        XCTAssertEqual(count(app, prefix: Self.recentPrefix), 0, "the shelf waits while the focus is in the grid")
        TVTest.capture("30-focus-kept-while-shelf-waits", in: self)

        step(app, .up, until: "tv.library.chip.", limit: 4)
        let shelf = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", Self.recentPrefix)).firstMatch
        XCTAssertTrue(shelf.waitForExistence(timeout: 5), "the shelf should join once the focus is in the header")
        TVTest.settle(1.0)
        TVTest.capture("31-shelf-joined", in: self)
    }

    func testFolderRefreshesWatchedStateAfterReturning() throws {
        try markWatched(false, key: "1008")
        let app = openTab("Movies")
        waitForRecents(in: app)
        enterContent(app)
        step(app, .up, until: "tv.library.chip.all", limit: 4)
        step(app, .right, until: "tv.library.folders", limit: 8)
        TVTest.remote.press(.select)
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tv.folder.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        TVTest.settle(1.0)
        TVTest.remote.press(.select)
        let poster = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tv.folder.media.'")).firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 10))
        TVTest.settle(1.5)
        let id = focusedIdentifier(app)
        XCTAssertTrue(id.hasPrefix("tv.folder.media."), "the first folder poster should have the focus, got \(id)")
        XCTAssertEqual(app.descendants(matching: .any)[id].value as? String, "Unwatched")
        TVTest.capture("32-folder-unwatched-before", in: self)

        TVTest.remote.press(.select)
        XCTAssertTrue(app.staticTexts.firstMatch.waitForExistence(timeout: 10))
        TVTest.settle(2.0)
        XCTAssertEqual(id, "tv.folder.media.1008")
        try markWatched(true, key: "1008")

        TVTest.remote.press(.menu)
        TVTest.settle(2.5)
        let cell = app.descendants(matching: .any)[id]
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        let updated = NSPredicate(format: "value == 'Watched'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: updated, object: cell)], timeout: 10), .completed, "the folder should show the new watched state after returning")
        TVTest.capture("33-folder-watched-after", in: self)
    }

    func testPaginationAndAlphabetJump() {
        let app = openTab("Movies")
        waitForRecents(in: app)
        enterContent(app)
        step(app, .down, until: Self.mediaPrefix, limit: 3)
        let first = focusedIdentifier(app)

        var moved = 0
        var previous = first
        for _ in 0..<18 {
            TVTest.remote.press(.down)
            TVTest.settle(0.35)
            let current = focusedIdentifier(app)
            if current != previous { moved += 1 }
            previous = current
        }
        XCTAssertEqual(moved, 18, "focus should keep moving down through 18 rows, so later pages were loaded")
        TVTest.capture("09-scrolled-deep-page-three", in: self)

        for _ in 0..<5 {
            TVTest.remote.press(.right)
        }
        TVTest.remote.press(.right)
        TVTest.settle(0.5)
        XCTAssertTrue(focusedIdentifier(app).hasPrefix(Self.railPrefix), "Right from the last column should reach the A-Z rail")
        TVTest.capture("10-rail-focused", in: self)

        let current = String(focusedIdentifier(app).dropFirst(Self.railPrefix.count))
        step(app, current > "M" ? .up : .down, until: "\(Self.railPrefix)M", limit: 30)
        TVTest.remote.press(.select)
        TVTest.settle(2.0)
        let landed = focusedElement(app)
        XCTAssertTrue(landed.identifier.hasPrefix(Self.mediaPrefix), "the jump should move focus onto a poster, got \(landed.identifier)")
        XCTAssertTrue(landed.label.hasPrefix("M"), "the jump to M should land on an M title, got \(landed.label)")
        TVTest.capture("11-after-jump-to-m", in: self)
    }

    func testContextMenuPlayAndOpen() {
        let app = openTab("Movies", environment: ["CRUCIBLE_PLAYER_HOLD": "6"])
        waitForRecents(in: app)
        enterContent(app)
        step(app, .down, until: Self.mediaPrefix, limit: 3)
        let poster = focusedIdentifier(app)

        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1.0)
        TVTest.capture("12-context-menu", in: self)
        XCTAssertTrue(app.descendants(matching: .any)["View Details"].waitForExistence(timeout: 3), "context menu did not appear")
        TVTest.remote.press(.menu)
        TVTest.settle(0.8)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: poster), "focus not restored after the menu closed")

        TVTest.remote.press(.playPause)
        XCTAssertTrue(app.otherElements["player.preroll"].waitForExistence(timeout: 60), "Play/Pause should start playback of the focused movie")
        TVTest.capture("13-play-pause-starts-the-player", in: self)
        for _ in 0..<6 where !app.tabBars.firstMatch.exists {
            TVTest.remote.press(.menu)
            TVTest.settle(2)
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "Menu leaves the player and returns to the library")
        TVTest.settle(1.5)

        TVTest.remote.press(.select)
        XCTAssertTrue(app.buttons["detail.action.primary"].waitForExistence(timeout: 15), "Select should open the movie detail")
        TVTest.settle(1.0)
        TVTest.capture("14-select-opens-detail", in: self)
    }

    func testRecentlyWatchedSeeAll() {
        let app = openTab("Movies")
        waitForRecents(in: app)
        enterContent(app)
        TVTest.remote.press(.right)
        step(app, .up, until: "tv.sectionHeader.seeAll", limit: 3)
        TVTest.capture("15-see-all-focused", in: self)
        TVTest.remote.press(.select)
        let halcyon = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Halcyon'")).firstMatch
        XCTAssertTrue(halcyon.waitForExistence(timeout: 10), "the Recently Watched screen should list the history")
        TVTest.settle(1.5)
        TVTest.capture("16-recently-watched-grid", in: self)
        TVTest.remote.press(.menu)
        TVTest.settle(1.0)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "tv.sectionHeader.seeAll"), "Back should return to the See All button")
    }

    func testShowLibrary() {
        let app = openTab("TV Shows")
        waitForPosters(in: app)
        enterContent(app)
        TVTest.settle(0.7)
        TVTest.capture("17-show-library-loaded", in: self)
        XCTAssertTrue(focusedIdentifier(app).hasPrefix(Self.recentPrefix) || focusedIdentifier(app).hasPrefix(Self.mediaPrefix))
    }

    func testFilterWithNoMatchesOffersClearFilters() {
        let app = openTab("TV Shows")
        waitForPosters(in: app)
        enterContent(app)
        step(app, .up, until: "tv.library.chip.all", limit: 4)
        step(app, .right, until: "tv.library.chip.inProgress", limit: 3)
        TVTest.remote.press(.select)
        let clear = app.buttons["Clear Filters"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10), "an empty filter result should offer Clear Filters")
        TVTest.settle(1.0)
        XCTAssertTrue(clear.hasFocus)
        TVTest.capture("18-no-matches", in: self)
        TVTest.remote.press(.select)
        waitForPosters(in: app)
        TVTest.settle(1.0)
        TVTest.capture("19-filters-cleared", in: self)
    }

    func testFailedLoadOffersTryAgain() {
        let app = openTab("Documentaries")
        let retry = app.buttons["Try Again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20), "a failed first page should show the error state")
        enterContent(app)
        TVTest.settle(0.5)
        XCTAssertTrue(retry.hasFocus)
        TVTest.capture("20-load-failed", in: self)
    }

    func testMoreTabListsOverflowLibrariesAndEmptyLibraryShowsEmptyState() {
        let app = openTab("More")
        let tile = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tv.more.library.'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "More should list the libraries that did not fit the tab bar")
        enterContent(app)
        TVTest.settle(2.0)
        TVTest.capture("21-more-tiles", in: self)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.staticTexts["No Shows"].waitForExistence(timeout: 15), "an empty library should say so")
        TVTest.settle(1.0)
        TVTest.capture("22-empty-library", in: self)
    }

    func testFolderBrowser() {
        let app = openTab("Movies")
        waitForRecents(in: app)
        enterContent(app)
        step(app, .up, until: "tv.library.chip.all", limit: 4)
        step(app, .right, until: "tv.library.folders", limit: 8)
        TVTest.capture("23-browse-folders-focused", in: self)
        TVTest.remote.press(.select)
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tv.folder.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the section's folders should be listed")
        TVTest.settle(1.5)
        TVTest.capture("24-folder-list", in: self)
        TVTest.remote.press(.select)
        let movie = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES '.*, (19|20)[0-9]{2}'")).firstMatch
        XCTAssertTrue(movie.waitForExistence(timeout: 10), "the folder's movies should be listed")
        TVTest.settle(1.5)
        TVTest.capture("25-folder-contents", in: self)
        TVTest.remote.press(.menu)
        TVTest.settle(1.0)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Back should return to the folder list")
    }

    /// Flips an item's watched state on the mock server behind the app's back.
    private func markWatched(_ watched: Bool, key: String) throws {
        let mock = try XCTUnwrap(ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"], "the mock URL was not forwarded")
        let verb = watched ? "scrobble" : "unscrobble"
        _ = try Data(contentsOf: XCTUnwrap(URL(string: "\(mock)/:/\(verb)?identifier=com.plexapp.plugins.library&key=\(key)")))
    }

    private func openTab(_ title: String, environment: [String: String] = [:]) -> XCUIApplication {
        let app = TVTest.launch(extraEnvironment: environment)
        addTeardownBlock { app.terminate() }
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30))
        TVTest.settle()
        for _ in 0..<8 where !tabBar.buttons[title].hasFocus {
            TVTest.remote.press(.right)
        }
        XCTAssertTrue(tabBar.buttons[title].hasFocus, "focus should reach the \(title) tab")
        TVTest.remote.press(.select)
        TVTest.settle(2.0)
        return app
    }

    /// Moves the focus from the tab bar into the screen. Call it once the screen has content, or the press has nothing to land on.
    private func enterContent(_ app: XCUIApplication) {
        TVTest.settle(0.8)
        TVTest.remote.press(.down)
        TVTest.settle(1.0)
        TVTest.capture("00-entered-content", in: self)
    }

    private func waitForPosters(in app: XCUIApplication) {
        let poster = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", Self.mediaPrefix)).firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 30), "no library poster appeared")
    }

    private func waitForRecents(in app: XCUIApplication) {
        let recent = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", Self.recentPrefix)).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 30), "no Recently Watched poster appeared")
        TVTest.settle(0.8)
    }

    private func focusedElement(_ app: XCUIApplication) -> XCUIElement {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
        return focused.allElementsBoundByIndex.first { !$0.identifier.isEmpty } ?? focused.firstMatch
    }

    private func focusedIdentifier(_ app: XCUIApplication) -> String {
        focusedElement(app).identifier
    }

    private func count(_ app: XCUIApplication, prefix: String) -> Int {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).count
    }

    /// Presses `direction` until the focused element's identifier is (or starts with) `identifier`.
    private func step(_ app: XCUIApplication, _ direction: XCUIRemote.Button, until identifier: String, limit: Int = 12) {
        for _ in 0..<limit {
            if focusedIdentifier(app).hasPrefix(identifier) { return }
            TVTest.remote.press(direction)
            TVTest.settle(0.45)
        }
        TVTest.capture("step-failed", in: self)
        XCTAssertTrue(focusedIdentifier(app).hasPrefix(identifier), "focus never reached \(identifier), stopped on \(focusedElement(app).debugDescription)")
    }
}
