import XCTest

/// Browses a library's collections and the viewer's playlists with the remote: a title's own link to its collection, the Collections button of
/// the library header, Add to Playlist from the detail screen, and the You tab's Playlists.
@MainActor
final class CollectionsAndPlaylistsTests: TVTestCase {
    private static let halcyon = "1001"
    private static let lowTide = "1003"

    private func openDetail(_ ratingKey: String) -> XCUIApplication {
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_STYLE": "dark"])
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        TVTest.settle()
        openFromOutside("crucible://item/\(ratingKey)?type=movie", in: app)
        XCTAssertTrue(app.buttons["detail.action.primary"].waitForExistence(timeout: 20), "detail never appeared")
        TVTest.settle(1.0)
        if !TVTest.waitForFocus(on: app, identifier: "detail.action.primary", timeout: 2) {
            TVTest.remote.press(.down)
        }
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.primary", timeout: 10), "primary action never took focus")
        TVTest.settle(1.0)
        return app
    }

    private func openFromOutside(_ link: String, in app: XCUIApplication) {
        let url = URL(string: link)!
        Task { _ = await UIApplication.shared.open(url) }
        let prompt = XCUIApplication(bundleIdentifier: "com.apple.PineBoard").buttons["Open"]
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if prompt.exists {
                TVTest.remote.press(.select)
                break
            }
            if app.buttons["detail.action.primary"].exists { break }
            TVTest.settle(0.5)
        }
        TVTest.settle(0.5)
    }

    private func capture(_ name: String) {
        TVTest.capture(name, in: self)
    }

    private func step(_ app: XCUIApplication, _ button: XCUIRemote.Button, until identifier: String, limit: Int = 12) {
        for _ in 0 ..< limit {
            if AppNavigation.focusedIdentifier(app).hasPrefix(identifier) { return }
            TVTest.remote.press(button)
            TVTest.settle(0.45)
        }
        XCTAssertTrue(AppNavigation.focusedIdentifier(app).hasPrefix(identifier), "focus never reached \(identifier), stopped on \(AppNavigation.focusedIdentifier(app))")
    }

    func testATitleLinksToItsCollection() {
        let app = openDetail(Self.halcyon)
        step(app, .right, until: "detail.action.collection")
        XCTAssertTrue(app.buttons["detail.action.collection"].label.contains("Salvage Stories"), app.buttons["detail.action.collection"].label)
        capture("01-collection-link-focused")
        TVTest.remote.press(.select)
        XCTAssertTrue(AppNavigation.element(app, "grid.1002").waitForExistence(timeout: 20), "the collection shows none of its titles")
        TVTest.settle(1.0)
        capture("02-collection-titles")
        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.collection"), "Menu must return to the title's link")
    }

    func testTheLibraryHeaderOpensTheCollections() {
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_STYLE": "dark"])
        AppNavigation.selectTab("Movies", in: app)
        let button = AppNavigation.element(app, "tv.library.collections")
        XCTAssertTrue(button.waitForExistence(timeout: 30), "the library header has no Collections button")
        TVTest.settle(1.5)
        TVTest.remote.press(.down)
        TVTest.settle(0.8)
        step(app, .up, until: "tv.chip.all", limit: 4)
        step(app, .right, until: "tv.library.collections", limit: 10)
        capture("01-collections-button-focused")
        TVTest.remote.press(.select)
        XCTAssertTrue(AppNavigation.element(app, "grid.9101").waitForExistence(timeout: 20), "the Collections screen lists no Salvage Stories")
        XCTAssertTrue(AppNavigation.element(app, "grid.9102").exists)
        TVTest.settle(1.0)
        capture("02-collections")
    }

    func testAddingATitleToAPlaylistAndFindingItInYou() {
        let app = openDetail(Self.lowTide)
        step(app, .right, until: "detail.action.playlist")
        TVTest.remote.press(.select)
        let friday = app.buttons["Friday Night"]
        XCTAssertTrue(friday.waitForExistence(timeout: 20), "the picker lists no Friday Night playlist")
        XCTAssertTrue(app.buttons["New Playlist…"].exists)
        TVTest.settle(0.8)
        capture("01-playlist-picker")
        TVTest.remote.press(.select)
        let confirmation = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Added to'")).firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 15), "adding showed no confirmation")
        XCTAssertTrue(confirmation.label.contains("Friday Night"), confirmation.label)
        capture("02-added")
        TVTest.remote.press(.select)

        AppNavigation.selectTab("You", in: app)
        let row = AppNavigation.element(app, "you.playlists")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "You has no Playlists row")
        AppNavigation.move(app, .down, untilFocusHasPrefix: "you.playlists", limit: 6)
        TVTest.remote.press(.select)
        let playlist = AppNavigation.firstElement(app, prefix: "grid.92")
        XCTAssertTrue(playlist.waitForExistence(timeout: 20), "Playlists lists nothing")
        TVTest.settle(1.0)
        capture("03-playlists")
        TVTest.remote.press(.select)
        XCTAssertTrue(AppNavigation.firstElement(app, prefix: "grid.1003#").waitForExistence(timeout: 20), "the playlist does not hold the title just added")
        TVTest.settle(1.0)
        capture("04-playlist-entries")
    }

    func testACastMemberOpensTheirTitles() {
        let app = openDetail(Self.halcyon)
        step(app, .down, until: "detail.cast.", limit: 6)
        TVTest.remote.press(.right)
        TVTest.remote.press(.right)
        TVTest.settle(0.6)
        capture("01-cast-focused")
        TVTest.remote.press(.select)
        XCTAssertTrue(AppNavigation.element(app, "grid.1001").waitForExistence(timeout: 20), "the cast member's titles do not include the title they are in")
        TVTest.settle(1.0)
        capture("02-filmography")
        TVTest.remote.press(.menu)
        XCTAssertTrue(AppNavigation.focusedIdentifier(app).hasPrefix("detail.cast."), "Menu must return to the cast card")
    }

    func testServerActivityListsTheStreams() {
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_STYLE": "dark"])
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.activity")
        XCTAssertTrue(AppNavigation.element(app, "grid.1001").waitForExistence(timeout: 20), "Server Activity lists no stream of Maren's")
        XCTAssertTrue(AppNavigation.element(app, "grid.4012").exists, "Server Activity lists no stream of Idris's")
        let caption = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Idris' AND label CONTAINS 'Paused, Transcoding'")).firstMatch
        XCTAssertTrue(caption.exists, "the converted, paused stream is not described")
        TVTest.settle(1.0)
        capture("01-server-activity")
    }
}
