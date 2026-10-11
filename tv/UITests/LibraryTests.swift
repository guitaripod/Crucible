import XCTest

/// Drives the Library tabs through the real focus engine against the mock Plex server. Run the mock with
/// `MOCK_LIBRARY_PAD=150 MOCK_FAIL_SECTIONS=3`: Movies grows to 150 items so pagination and the A-Z jump
/// have something to do, and Documentaries fails to load. The other libraries keep their default content;
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
        let app = openTab("Movies")
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
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "Play/Pause should start playback of the focused movie")
        TVTest.capture("13-play-pause-reaches-player-seam", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(0.8)

        TVTest.remote.press(.select)
        XCTAssertTrue(app.staticTexts["placeholder.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["placeholder.title"].label.hasPrefix("Detail "), "Select should open the movie detail")
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

    private func openTab(_ title: String) -> XCUIApplication {
        let app = TVTest.launch()
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
