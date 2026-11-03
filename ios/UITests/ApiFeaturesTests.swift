import XCTest

/// The rest of what the app does with the Plex API on the iPhone and the iPad: a title's trailers, library filters beyond genre, searching for
/// subtitles online, the watchlist and playing a playlist from its start. Each runs against the built-in demo.
@MainActor
final class ApiFeaturesTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func enterDemo() -> XCUIApplication {
        let app = IOSTest.launch()
        let demo = IOSTest.element(app, "onboarding.demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 120), "Welcome never showed Try the demo")
        demo.tap()
        let start = IOSTest.element(app, "demo.intro.start")
        XCTAssertTrue(start.waitForExistence(timeout: 180), "the demo intro never appeared")
        start.tap()
        XCTAssertTrue(IOSTest.wait(for: start, "exists == false OR hittable == false", timeout: 30), "the intro never closed")
        IOSTest.settle(2)
        return app
    }

    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let bar = app.tabBars.buttons[name]
        return bar.waitForExistence(timeout: 5) ? bar : app.buttons.matching(identifier: name).firstMatch
    }

    private func card(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    private func openTitle(_ app: XCUIApplication, _ title: String) {
        let search = tab(app, "Search")
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        let field = app.searchFields.firstMatch
        for _ in 0..<3 where !field.exists {
            search.tap()
            _ = field.waitForExistence(timeout: 10)
        }
        field.tap()
        field.typeText(title)
        let result = card(app, title)
        XCTAssertTrue(result.waitForExistence(timeout: 60), "search found no \(title)")
        result.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Rate' OR label BEGINSWITH 'Your rating'")).firstMatch.waitForExistence(timeout: 30), "\(title) never opened")
    }

    func testATrailerPlaysFromTheExtrasShelf() {
        let app = enterDemo()
        openTitle(app, "Deep Field")
        let trailer = app.cells.containing(NSPredicate(format: "label CONTAINS 'Official Trailer'")).firstMatch
        for _ in 0..<6 where !trailer.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(trailer.waitForExistence(timeout: 20), "the detail has no trailer in its extras shelf")
        IOSTest.capture("01-extras-shelf", in: self)
        trailer.tap()
        let rate = app.buttons.matching(NSPredicate(format: "label == 'Rate' OR label BEGINSWITH 'Your rating'")).firstMatch
        XCTAssertTrue(IOSTest.wait(for: rate, "hittable == false", timeout: 40), "tapping the trailer did not open the player")
        IOSTest.settle(3)
        IOSTest.capture("02-trailer-playing", in: self)
    }

    func testTheLibraryFiltersByDecade() {
        let app = enterDemo()
        let library = tab(app, "Library")
        XCTAssertTrue(library.waitForExistence(timeout: 30))
        library.tap()
        let decade = app.buttons["Decade"]
        XCTAssertTrue(decade.waitForExistence(timeout: 60), "the library header has no Decade filter")
        IOSTest.capture("01-chips", in: self)
        decade.tap()
        let choice = app.buttons.matching(NSPredicate(format: "label ENDSWITH '0s' AND label != 'All Decades'")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "the Decade menu lists no decade")
        let chosen = choice.label
        choice.tap()
        XCTAssertTrue(app.buttons[chosen].waitForExistence(timeout: 20), "the chip does not show \(chosen)")
        IOSTest.capture("02-filtered", in: self)
        XCTAssertTrue(app.buttons["All"].exists)
        app.buttons["All"].tap()
        XCTAssertTrue(app.buttons["Decade"].waitForExistence(timeout: 20), "All did not clear the decade filter")
    }

    func testSubtitlesAreSearchedOnlineAndKept() {
        let app = enterDemo()
        openTitle(app, "Low Tide")
        let subtitles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Subtitles'")).firstMatch
        XCTAssertTrue(subtitles.waitForExistence(timeout: 20), "the detail has no Subtitles button")
        subtitles.tap()
        let before = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'English'")).count
        let search = app.buttons["Search for Subtitles…"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "the Subtitles menu offers no online search")
        search.tap()
        let candidate = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'subtitles.candidate.'")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 30), "the search listed no subtitle")
        IOSTest.capture("01-subtitle-results", in: self)
        candidate.tap()
        let language = IOSTest.element(app, "subtitles.language")
        XCTAssertTrue(IOSTest.wait(for: language, "exists == false", timeout: 30), "the sheet did not close after the download")
        IOSTest.settle(1.5)
        subtitles.tap()
        XCTAssertTrue(app.buttons["Search for Subtitles…"].waitForExistence(timeout: 10))
        let after = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'English'")).count
        XCTAssertGreaterThan(after, before, "the downloaded subtitle is not among the title's tracks")
        IOSTest.capture("02-subtitle-menu", in: self)
    }

    func testTheWatchlistOpensTitlesOnTheServerAndExplainsTheOthers() {
        let app = enterDemo()
        tab(app, "You").tap()
        let row = IOSTest.element(app, "you.watchlist")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "You has no Watchlist row")
        row.tap()
        let missing = card(app, "Night Train to Nowhere")
        XCTAssertTrue(missing.waitForExistence(timeout: 30), "the watchlist lists no Night Train")
        IOSTest.capture("01-watchlist", in: self)
        missing.tap()
        XCTAssertTrue(app.alerts["Not in Your Library"].waitForExistence(timeout: 20), "a title the server lacks explained nothing")
        app.alerts.buttons["OK"].tap()
        let local = app.cells.containing(NSPredicate(format: "label BEGINSWITH 'Halcyon, 2021'")).firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 20))
        local.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Rate' OR label BEGINSWITH 'Your rating'")).firstMatch.waitForExistence(timeout: 30), "a title on the server did not open")
        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        XCTAssertTrue(app.buttons["Remove from Watchlist"].waitForExistence(timeout: 20), "a watchlisted title offers no way off the watchlist")
        IOSTest.capture("02-detail-menu", in: self)
    }

    func testAPlaylistPlaysFromItsStart() {
        let app = enterDemo()
        tab(app, "You").tap()
        let row = IOSTest.element(app, "you.playlists")
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        let playlist = card(app, "Friday Night")
        XCTAssertTrue(playlist.waitForExistence(timeout: 30))
        playlist.tap()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "the playlist has no Play button")
        XCTAssertTrue(IOSTest.wait(for: play, "isEnabled == true", timeout: 20))
        let options = app.buttons["Playlist Options"]
        play.tap()
        XCTAssertTrue(IOSTest.wait(for: options, "hittable == false", timeout: 40), "Play did not open the player")
        IOSTest.settle(3)
        IOSTest.capture("01-playlist-playing", in: self)
    }
}
