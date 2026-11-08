import XCTest

/// Connects the demo's stand-in Seerr, which Crucible finds by itself, then requests a watchlist title the server lacks,
/// asks for a library show's missing season and lists the requests, where the owner approves Sam's.
@MainActor
final class SeerrTests: XCTestCase {
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

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 6) {
        for _ in 0..<attempts where !element.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
    }

    /// A row of the Requests screen, found by its title.
    private func request(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'seerr.requests.' AND label CONTAINS %@", title)).firstMatch
    }

    private func connect(_ app: XCUIApplication) {
        IOSTest.tab(app, "You").tap()
        let settings = IOSTest.element(app, "you.settings")
        scrollTo(settings, in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "You has no Settings row")
        settings.tap()
        let category = IOSTest.element(app, "settings.category.integrations")
        scrollTo(category, in: app, attempts: 4)
        XCTAssertTrue(category.waitForExistence(timeout: 20), "Settings has no Integrations")
        category.tap()
        let seerr = IOSTest.element(app, "settings.dest.seerr")
        XCTAssertTrue(seerr.waitForExistence(timeout: 20), "Integrations has no Seerr row")
        IOSTest.settle(1)
        IOSTest.capture("00-integrations", in: self)
        seerr.tap()
        let found = IOSTest.element(app, "seerr.found")
        XCTAssertTrue(found.waitForExistence(timeout: 30), "Crucible did not find the demo's Seerr")
        IOSTest.capture("01-seerr-found", in: self)
        IOSTest.element(app, "seerr.connect").tap()
        let user = IOSTest.element(app, "seerr.user")
        XCTAssertTrue(user.waitForExistence(timeout: 30), "connecting never showed the Seerr account")
        let named = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Demo Viewer")).firstMatch
        XCTAssertTrue(named.waitForExistence(timeout: 10), "the Seerr account is not named")
        XCTAssertTrue(IOSTest.element(app, "seerr.requests").exists, "a connected Seerr offers no Requests")
        IOSTest.capture("02-seerr-connected", in: self)
    }

    func testRequestingAWatchlistTitleTheServerLacks() {
        let app = enterDemo()
        connect(app)
        IOSTest.tab(app, "You").tap()
        IOSTest.tab(app, "You").tap()
        let watchlist = IOSTest.element(app, "you.watchlist")
        XCTAssertTrue(watchlist.waitForExistence(timeout: 20), "You has no Watchlist row")
        watchlist.tap()
        let missing = app.cells.containing(NSPredicate(format: "label CONTAINS %@", "Night Train to Nowhere")).firstMatch
        XCTAssertTrue(missing.waitForExistence(timeout: 30), "the watchlist lists no Night Train")
        let labelled = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Night Train to Nowhere", "Not on your server")).firstMatch
        XCTAssertTrue(labelled.waitForExistence(timeout: 30), "the watchlist card does not say the server lacks the title")
        IOSTest.capture("03a-watchlist-states", in: self)
        missing.tap()
        let submit = IOSTest.element(app, "seerr.request.submit")
        XCTAssertTrue(submit.waitForExistence(timeout: 30), "the Request sheet offers no Request")
        IOSTest.capture("03-request-sheet", in: self)
        submit.tap()
        let header = IOSTest.element(app, "seerr.header")
        XCTAssertTrue(IOSTest.wait(for: header, "label CONTAINS 'Downloading 35%'", timeout: 30), "the requested title does not show its download")
        XCTAssertTrue(IOSTest.element(app, "seerr.request.watchlisted").waitForExistence(timeout: 10), "the sheet does not say the title stays on the watchlist")
        IOSTest.capture("04-requested-downloading", in: self)
        IOSTest.element(app, "seerr.request.close").tap()

        IOSTest.tab(app, "You").tap()
        IOSTest.tab(app, "You").tap()
        let requests = IOSTest.element(app, "you.requests")
        XCTAssertTrue(requests.waitForExistence(timeout: 20), "You has no Requests row once Seerr is connected")
        requests.tap()
        let train = request(app, "Night Train to Nowhere")
        XCTAssertTrue(train.waitForExistence(timeout: 30), "Requests does not list the new request")
        IOSTest.capture("05-requests-mine", in: self)
        app.segmentedControls.buttons["Awaiting Approval"].tap()
        let sams = request(app, "Lowland Choir")
        XCTAssertTrue(sams.waitForExistence(timeout: 30), "the owner does not see Sam's request waiting")
        XCTAssertTrue(sams.label.contains("Sam"), "Sam's request does not say who asked")
        IOSTest.capture("06-requests-awaiting", in: self)
        sams.swipeLeft()
        let approve = app.buttons["Approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "a waiting request offers no Approve")
        approve.tap()
        XCTAssertTrue(IOSTest.wait(for: sams, "exists == false", timeout: 30), "approving left the request waiting")
    }

    func testSearchOffersTitlesTheServerLacks() {
        let app = enterDemo()
        connect(app)
        IOSTest.tab(app, "Search").tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the search field never appeared")
        field.tap()
        field.typeText("Glass")
        let elsewhere = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Glass Orchard")).firstMatch
        XCTAssertTrue(elsewhere.waitForExistence(timeout: 30), "search does not offer Glass Orchard from Seerr")
        let local = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Glass Harbour")).firstMatch
        XCTAssertTrue(local.exists, "the server's own match is missing next to Seerr's")
        app.keyboards.buttons.matching(NSPredicate(format: "label == 'search' OR label == 'Search'")).firstMatch.tap()
        IOSTest.settle(1)
        for _ in 0..<4 where !elsewhere.isHittable {
            app.collectionViews.firstMatch.swipeUp()
            IOSTest.settle(1)
        }
        IOSTest.capture("09-search-elsewhere", in: self)
        elsewhere.tap()
        let submit = IOSTest.element(app, "seerr.request.submit")
        XCTAssertTrue(submit.waitForExistence(timeout: 30), "a Seerr result opens no Request sheet")
        XCTAssertTrue(IOSTest.element(app, "seerr.season.3").waitForExistence(timeout: 10), "the show's seasons are not listed")
        IOSTest.capture("10-search-request-sheet", in: self)
    }

    func testAShowMissingASeasonOffersRequestMoreSeasons() {
        let app = enterDemo()
        connect(app)
        IOSTest.tab(app, "Search").tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the search field never appeared")
        field.tap()
        field.typeText("Salt Road")
        let result = app.cells.containing(NSPredicate(format: "label CONTAINS %@", "The Salt Road")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 60), "search found no Salt Road")
        result.tap()
        let more = app.navigationBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 20), "the show has no More menu")
        more.tap()
        let request = app.buttons["Request More Seasons"]
        XCTAssertTrue(request.waitForExistence(timeout: 20), "More has no Request More Seasons")
        request.tap()
        let season = IOSTest.element(app, "seerr.season.5")
        XCTAssertTrue(season.waitForExistence(timeout: 30), "the sheet does not list the missing season")
        XCTAssertTrue(IOSTest.element(app, "seerr.season.1").exists, "the sheet does not list the seasons on the server")
        IOSTest.capture("07-request-more-seasons", in: self)
        IOSTest.element(app, "seerr.request.submit").tap()
        XCTAssertTrue(IOSTest.wait(for: IOSTest.element(app, "seerr.request.submit"), "exists == false", timeout: 30), "requesting the last missing season still offers Request")
        XCTAssertTrue(IOSTest.wait(for: season, "label CONTAINS 'On its way'", timeout: 20), "the requested season does not say it is on its way")
        IOSTest.capture("08-season-requested", in: self)
    }
}
