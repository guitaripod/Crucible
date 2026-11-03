import XCTest

/// Browses the demo library's collections from the Movies library and from a title's own link, and builds a playlist: adding a title from its
/// menu, opening the playlist from You, and editing it from a card's menu. The demo keeps playlists between launches, so every check names
/// what it needs rather than what the first run left.
@MainActor
final class CollectionsAndPlaylistsTests: XCTestCase {
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

    /// The tab called `name`: in the tab bar of an iPhone, among the buttons of the pill an iPad draws.
    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let bar = app.tabBars.buttons[name]
        return bar.waitForExistence(timeout: 5) ? bar : app.buttons.matching(identifier: name).firstMatch
    }

    private func card(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    private func openMoviesLibrary(_ app: XCUIApplication) {
        let library = tab(app, "Library")
        XCTAssertTrue(library.waitForExistence(timeout: 30), "the tab bar has no Library")
        library.tap()
        XCTAssertTrue(app.buttons["Collections"].waitForExistence(timeout: 60), "the library grid shows no Collections chip")
    }

    func testCollectionsOpenFromTheLibraryAndFromATitle() {
        let app = enterDemo()
        openMoviesLibrary(app)
        IOSTest.capture("01-library-chips", in: self)

        app.buttons["Collections"].tap()
        let salvage = card(app, "Salvage Stories")
        XCTAssertTrue(salvage.waitForExistence(timeout: 30), "the Collections screen lists no Salvage Stories")
        XCTAssertTrue(card(app, "After Dark").exists)
        IOSTest.capture("02-collections", in: self)

        salvage.tap()
        let halcyon = card(app, "Halcyon")
        XCTAssertTrue(halcyon.waitForExistence(timeout: 30), "the collection shows none of its titles")
        XCTAssertTrue(card(app, "Deep Field").exists)
        IOSTest.capture("03-collection-titles", in: self)

        halcyon.tap()
        let pill = app.buttons["Part of the Salvage Stories collection"]
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "the title shows no link to its collection")
        IOSTest.capture("04-title-collection-link", in: self)
        pill.tap()
        XCTAssertTrue(card(app, "Deep Field").waitForExistence(timeout: 30), "the collection link did not open the collection")
    }

    func testAPlaylistTakesATitleFromItsMenu() {
        let app = enterDemo()
        let search = tab(app, "Search")
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the search field never appeared")
        field.tap()
        field.typeText("Low Tide")
        let result = card(app, "Low Tide")
        XCTAssertTrue(result.waitForExistence(timeout: 60), "search found no Low Tide")
        result.tap()

        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 30), "the detail has no More menu")
        more.tap()
        let addMenu = app.buttons["Add to Playlist"]
        XCTAssertTrue(addMenu.waitForExistence(timeout: 10), "the More menu offers no Add to Playlist")
        addMenu.tap()
        let friday = app.buttons["Friday Night"]
        XCTAssertTrue(friday.waitForExistence(timeout: 15), "the menu lists no Friday Night playlist")
        XCTAssertTrue(app.buttons["New Playlist…"].exists, "the menu offers no New Playlist")
        IOSTest.capture("01-add-to-playlist-menu", in: self)
        friday.tap()
        IOSTest.settle(1.5)

        tab(app, "You").tap()
        let row = IOSTest.element(app, "you.playlists")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "You has no Playlists row")
        row.tap()
        let playlist = card(app, "Friday Night")
        XCTAssertTrue(playlist.waitForExistence(timeout: 30), "Playlists lists no Friday Night")
        IOSTest.capture("02-playlists", in: self)
        playlist.tap()
        XCTAssertTrue(card(app, "Low Tide").waitForExistence(timeout: 30), "the playlist does not hold the title just added")
        XCTAssertTrue(card(app, "Cold Meridian").exists)
        IOSTest.capture("03-playlist-entries", in: self)
    }

    func testANewPlaylistIsMadeFromATitlesMenu() {
        let app = enterDemo()
        tab(app, "Search").tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText("Moth Season")
        let result = card(app, "Moth Season")
        XCTAssertTrue(result.waitForExistence(timeout: 60))
        result.tap()
        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        more.tap()
        app.buttons["Add to Playlist"].tap()
        let create = app.buttons["New Playlist…"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        create.tap()
        let name = app.textFields["playlist.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "New Playlist asked for no name")
        name.typeText("Rainy Sundays")
        IOSTest.capture("01-name-prompt", in: self)
        app.buttons["Create"].tap()
        IOSTest.settle(1.5)

        tab(app, "You").tap()
        let row = IOSTest.element(app, "you.playlists")
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        XCTAssertTrue(card(app, "Rainy Sundays").waitForExistence(timeout: 30), "the new playlist is not listed")
        IOSTest.capture("02-new-playlist-listed", in: self)
    }

    func testACastMemberOpensTheirTitles() {
        let app = enterDemo()
        tab(app, "Search").tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText("Cold Meridian")
        let result = card(app, "Cold Meridian")
        XCTAssertTrue(result.waitForExistence(timeout: 60))
        result.tap()
        let person = app.cells.containing(NSPredicate(format: "label CONTAINS %@", "Dario Kemp")).firstMatch
        for _ in 0..<6 where !person.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(person.waitForExistence(timeout: 20), "the cast rail does not list Dario Kemp")
        IOSTest.capture("01-cast-rail", in: self)
        person.tap()
        XCTAssertTrue(card(app, "Cold Meridian").waitForExistence(timeout: 30), "the cast member's titles do not include the title they are in")
        IOSTest.capture("02-filmography", in: self)
    }

    func testServerActivityListsWhoIsWatching() {
        let app = enterDemo()
        tab(app, "You").tap()
        let row = IOSTest.element(app, "you.activity")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "You has no Server Activity row")
        row.tap()
        let playing = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Maren' AND label CONTAINS 'Playing'")).firstMatch
        XCTAssertTrue(playing.waitForExistence(timeout: 30), "Server Activity lists no playing stream of Maren's")
        let converted = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Idris' AND label CONTAINS 'Paused, Transcoding'")).firstMatch
        XCTAssertTrue(converted.exists, "the converted, paused stream is not listed")
        IOSTest.capture("01-server-activity", in: self)
    }
}
