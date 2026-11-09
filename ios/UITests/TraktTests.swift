import XCTest

/// Connects Trakt in the demo, whose stand-in Trakt approves the device code by itself, and checks what the plugin adds:
/// Settings › Integrations › Trakt, the ratings strip on a detail page and Check In in its menu.
@MainActor
final class TraktTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func enterDemo() -> XCUIApplication {
        let app = IOSTest.launch()
        let demo = IOSTest.element(app, "onboarding.demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 60), "Welcome never showed Try the demo")
        demo.tap()
        let start = IOSTest.element(app, "demo.intro.start")
        XCTAssertTrue(start.waitForExistence(timeout: 120), "the demo intro never appeared")
        start.tap()
        XCTAssertTrue(IOSTest.wait(for: start, "exists == false OR hittable == false", timeout: 30), "the intro never closed")
        IOSTest.settle(2)
        return app
    }

    private func openTraktSettings(_ app: XCUIApplication) {
        IOSTest.tab(app, "You").tap()
        let settings = IOSTest.element(app, "you.settings")
        for _ in 0..<6 where !settings.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "You has no Settings row")
        settings.tap()
        let category = IOSTest.element(app, "settings.category.integrations")
        for _ in 0..<4 where !category.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(category.waitForExistence(timeout: 20), "Settings has no Integrations")
        category.tap()
        let trakt = IOSTest.element(app, "settings.dest.trakt")
        XCTAssertTrue(trakt.waitForExistence(timeout: 20), "Integrations has no Trakt row")
        trakt.tap()
        XCTAssertTrue(IOSTest.element(app, "settings.trakt").waitForExistence(timeout: 20), "Trakt settings never opened")
    }

    private func connect(_ app: XCUIApplication) {
        let connect = IOSTest.element(app, "trakt.connect")
        XCTAssertTrue(connect.waitForExistence(timeout: 20), "Trakt offers no Connect")
        IOSTest.capture("01-trakt-before-connecting", in: self)
        connect.tap()
        let code = IOSTest.element(app, "trakt.code")
        XCTAssertTrue(code.waitForExistence(timeout: 20), "the connect sheet never showed the code")
        IOSTest.capture("02-trakt-code", in: self)
        let profile = IOSTest.element(app, "trakt.profile")
        XCTAssertTrue(profile.waitForExistence(timeout: 30), "the demo's approval never connected Trakt")
        IOSTest.settle(1)
        IOSTest.capture("03-trakt-connected", in: self)
    }

    /// With Trakt connected, Statistics counts everything Trakt knows: Everything adds the show and the two films watched on
    /// streaming services, while the plays Crucible sent to Trakt from the server are not counted twice; Plex goes back to the
    /// server's own history.
    func testStatisticsBringInEverythingTraktKnows() {
        let app = enterDemo()
        openTraktSettings(app)
        connect(app)
        IOSTest.tab(app, "You").tap()
        IOSTest.tab(app, "You").tap()
        let statistics = IOSTest.element(app, "you.statistics")
        for _ in 0..<6 where !statistics.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(statistics.waitForExistence(timeout: 20), "You has no Statistics row")
        statistics.tap()
        let everything = app.buttons["stats.source.everything"]
        let plex = app.buttons["stats.source.plex"]
        XCTAssertTrue(everything.waitForExistence(timeout: 30), "Statistics offers no Everything with Trakt connected")
        plex.tap()
        IOSTest.settle(4)
        let plexShows = tile(app, "Shows")
        let plexMovies = tile(app, "Movies")
        IOSTest.capture("06-statistics-plex", in: self)
        everything.tap()
        XCTAssertTrue(IOSTest.wait(for: tileElement(app, "Shows"), "label CONTAINS ', \(plexShows + 1)'", timeout: 30), "Everything does not add the show watched elsewhere")
        XCTAssertEqual(tile(app, "Shows"), plexShows + 1, "a show partly watched elsewhere is still one show")
        XCTAssertEqual(tile(app, "Movies"), plexMovies + 2, "Everything adds the two films watched elsewhere")
        IOSTest.settle(1)
        IOSTest.capture("07-statistics-everything", in: self)
    }

    private func tileElement(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
    }

    /// The number a statistics tile shows, read from its VoiceOver label ("Shows, 23").
    private func tile(_ app: XCUIApplication, _ title: String) -> Int {
        let element = tileElement(app, title)
        XCTAssertTrue(element.waitForExistence(timeout: 20), "Statistics shows no \(title) tile")
        let parts = element.label.components(separatedBy: ", ")
        return parts.count > 1 ? Int(parts[1].filter(\.isNumber)) ?? -1 : -1
    }

    func testConnectingShowsTheAccountAndWhatIsSent() {
        let app = enterDemo()
        openTraktSettings(app)
        connect(app)
        let named = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Demo Viewer")).firstMatch
        XCTAssertTrue(named.waitForExistence(timeout: 10), "the connected account is not named")
        XCTAssertTrue(IOSTest.element(app, "trakt.scrobble").exists, "Scrobble Playback is missing")
        XCTAssertTrue(IOSTest.element(app, "trakt.anotherApp").exists, "Another App Records My Plays is missing")
        IOSTest.element(app, "trakt.disconnect").tap()
        let confirm = app.sheets.buttons["Disconnect"].exists ? app.sheets.buttons["Disconnect"] : app.buttons["Disconnect"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Disconnect asks nothing")
        confirm.tap()
        XCTAssertTrue(IOSTest.element(app, "trakt.connect").waitForExistence(timeout: 20), "disconnecting did not bring Connect back")
    }

    /// Trakt's score sits on the hero's meta line beside Plex's own rating, under its mark, instead of a strip of its own.
    func testAConnectedDetailPageShowsTraktBesidePlexsRatingAndCheckIn() {
        let app = enterDemo()
        openTraktSettings(app)
        connect(app)
        IOSTest.tab(app, "Search").tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the search field never appeared")
        field.tap()
        field.typeText("Halcyon")
        let result = app.cells.containing(NSPredicate(format: "label CONTAINS %@", "Halcyon")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 60), "search found no Halcyon")
        result.tap()
        let hero = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", ".*Trakt [0-9]+%.*")).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 30), "the hero's meta line has no Trakt score")
        XCTAssertFalse(app.staticTexts["Ratings"].exists, "the separate ratings strip is gone")
        IOSTest.settle(1)
        IOSTest.capture("04-detail-inline-ratings", in: self)

        let more = app.navigationBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "the detail has no More menu")
        more.tap()
        let checkIn = app.buttons["Check In"]
        XCTAssertTrue(checkIn.waitForExistence(timeout: 10), "More has no Check In")
        checkIn.tap()
        IOSTest.settle(1.2)
        IOSTest.capture("05-after-check-in", in: self)
        more.tap()
        let cancel = app.buttons["Cancel Check-In"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "a checked-in title does not offer Cancel Check-In")
        cancel.tap()
        IOSTest.settle(1.2)
        more.tap()
        XCTAssertTrue(app.buttons["Check In"].waitForExistence(timeout: 10), "cancelling did not bring Check In back")
        IOSTest.capture("05-checked-in", in: self)
    }
}
