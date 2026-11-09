import XCTest

/// Settings search and categories, Home's row arrangement, Rate What You Watched and Remove from Continue Watching, each against the
/// built-in demo on the iPhone.
@MainActor
final class SettingsAndRatingTests: XCTestCase {
    private static let finished = "m:1003:Low Tide,s:2001:The Salt Road:4001"

    override func setUp() {
        continueAfterFailure = false
    }

    private func enterDemo(_ environment: [String: String] = [:]) -> XCUIApplication {
        let app = IOSTest.launch(extraEnvironment: environment)
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
        IOSTest.tab(app, name)
    }

    private func openSettings(_ app: XCUIApplication) {
        tab(app, "You").tap()
        let settings = IOSTest.element(app, "you.settings")
        for _ in 0..<6 where !settings.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "You has no Settings row")
        settings.tap()
        XCTAssertTrue(IOSTest.element(app, "settings.root").waitForExistence(timeout: 20), "Settings never opened")
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, limit: Int = 8) {
        for _ in 0..<limit where !element.isHittable {
            app.collectionViews.firstMatch.swipeUp()
            IOSTest.settle(0.4)
        }
    }

    /// Every category, at the default text size, so each row's value can be checked whole: a value sits at the row's end or
    /// under its title, never cut short.
    func testEveryCategoryShowsItsValuesWhole() {
        walkCategories(prefix: "values")
    }

    /// The same walk at an accessibility text size, where every value moves under its title.
    func testEveryCategoryShowsItsValuesWholeAtLargeText() {
        walkCategories(prefix: "values-large", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
    }

    private func walkCategories(prefix: String, arguments: [String] = []) {
        let app = IOSTest.launch(arguments: arguments)
        let demo = IOSTest.element(app, "onboarding.demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 120), "Welcome never showed Try the demo")
        demo.tap()
        let start = IOSTest.element(app, "demo.intro.start")
        XCTAssertTrue(start.waitForExistence(timeout: 180), "the demo intro never appeared")
        start.tap()
        XCTAssertTrue(IOSTest.wait(for: start, "exists == false OR hittable == false", timeout: 30), "the intro never closed")
        IOSTest.settle(2)
        openSettings(app)
        let categories = ["playback", "controls", "home", "downloads", "notifications", "integrations", "appearance", "connection", "privacy", "help"]
        for (index, category) in categories.enumerated() {
            let row = IOSTest.element(app, "settings.category.\(category)")
            scrollTo(row, in: app, limit: 10)
            XCTAssertTrue(row.waitForExistence(timeout: 10), "Settings has no \(category)")
            row.tap()
            let list = app.collectionViews["settings.category.\(category)"]
            XCTAssertTrue(list.waitForExistence(timeout: 10), "\(category) never opened")
            IOSTest.settle(1.5)
            for page in 0..<4 {
                IOSTest.capture(String(format: "%@-%02d-%@-%d", prefix, index, category, page), in: self)
                let before = list.cells.firstMatch.frame
                list.swipeUp()
                IOSTest.settle(0.8)
                if list.cells.firstMatch.frame == before { break }
            }
            app.navigationBars.buttons.firstMatch.tap()
            IOSTest.settle(1)
        }
    }

    func testSearchFindsASettingAndItsCategoryHighlightsIt() {
        let app = enterDemo()
        openSettings(app)
        IOSTest.capture("01-settings-root", in: self)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Settings has no search field")
        field.tap()
        field.typeText("captions")
        let result = IOSTest.element(app, "settings.pref.subtitleSize")
        XCTAssertTrue(result.waitForExistence(timeout: 10), "searching captions did not find Subtitle Size")
        IOSTest.capture("02-search-captions", in: self)
        result.tap()
        XCTAssertTrue(IOSTest.element(app, "settings.category.playback").waitForExistence(timeout: 10), "the result did not open Playback")
        XCTAssertTrue(IOSTest.element(app, "settings.pref.subtitleSize").waitForExistence(timeout: 10))
        IOSTest.capture("03-playback-category", in: self)
    }

    func testAToggleInACategoryFlipsAndRestoreDefaultsPutsItBack() {
        let app = enterDemo()
        openSettings(app)
        IOSTest.element(app, "settings.category.playback").tap()
        let autoplay = IOSTest.element(app, "settings.pref.autoplayNextEpisode")
        XCTAssertTrue(autoplay.waitForExistence(timeout: 10))
        let toggle = autoplay.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Autoplay Next Episode has no switch")
        let before = toggle.value as? String
        toggle.tap()
        IOSTest.settle(0.5)
        XCTAssertNotEqual(toggle.value as? String, before, "the switch did not flip")
        let restore = IOSTest.element(app, "settings.restoreDefaults")
        scrollTo(restore, in: app)
        XCTAssertTrue(restore.waitForExistence(timeout: 5), "a changed category offers Restore Defaults")
        IOSTest.capture("01-changed-playback", in: self)
        restore.tap()
        let confirm = app.alerts.buttons["Restore"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        IOSTest.settle(0.8)
        XCTAssertFalse(IOSTest.element(app, "settings.restoreDefaults").exists, "Restore Defaults stays after restoring")
    }

    func testHomeRowsHideRecentlyAddedOnHome() {
        let app = enterDemo()
        openSettings(app)
        IOSTest.element(app, "settings.category.home").tap()
        let rows = IOSTest.element(app, "settings.dest.homeRows")
        XCTAssertTrue(rows.waitForExistence(timeout: 10))
        rows.tap()
        let recent = IOSTest.element(app, "settings.homeRows.recentlyAdded")
        XCTAssertTrue(recent.waitForExistence(timeout: 10), "Home Rows lists no Recently Added")
        recent.switches.firstMatch.tap()
        IOSTest.settle(0.6)
        IOSTest.capture("01-home-rows", in: self)
        tab(app, "Home").tap()
        IOSTest.settle(2)
        XCTAssertFalse(app.staticTexts["Recently Added"].exists, "Recently Added still shows on Home")
        IOSTest.capture("02-home-without-recently-added", in: self)
        tab(app, "You").tap()
        IOSTest.settle(1)
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        app.navigationBars.buttons["Reset"].tap()
        IOSTest.settle(0.6)
        XCTAssertEqual(recent.switches.firstMatch.value as? String, "1")
    }

    func testRateWhatYouWatchedRatesFromHomeAndTheCardLeaves() {
        let app = enterDemo(["CRUCIBLE_FINISHED": Self.finished])
        tab(app, "Home").tap()
        let card = IOSTest.element(app, "home.rate.1003")
        scrollTo(card, in: app, limit: 10)
        XCTAssertTrue(card.waitForExistence(timeout: 30), "Rate What You Watched never showed Low Tide")
        XCTAssertTrue(IOSTest.element(app, "home.rate.2001").exists, "the show the viewer caught up with is asked about too")
        IOSTest.capture("01-rate-row", in: self)
        card.tap()
        let stars = app.descendants(matching: .any).matching(identifier: "Your Rating").firstMatch
        XCTAssertTrue(stars.waitForExistence(timeout: 10), "the rating sheet never opened")
        IOSTest.capture("02-rating-sheet", in: self)
        stars.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(IOSTest.wait(for: card, "exists == false", timeout: 20), "the rated movie stayed in the row")
        IOSTest.capture("03-after-rating", in: self)
        clearRating(of: "Low Tide", in: app)
    }

    func testSeeAllRatesEachTitleInPlaceAndHomeLetsThemGo() {
        let app = enterDemo(["CRUCIBLE_FINISHED": Self.finished])
        tab(app, "Home").tap()
        let card = IOSTest.element(app, "home.rate.1003")
        scrollTo(card, in: app, limit: 10)
        XCTAssertTrue(card.waitForExistence(timeout: 30), "Rate What You Watched never showed Low Tide")
        let seeAll = app.buttons["See All Rate What You Watched"]
        XCTAssertTrue(seeAll.waitForExistence(timeout: 10), "the Rate What You Watched row has no See All")
        seeAll.tap()
        let movieStars = IOSTest.element(app, "rateWatched.stars.1003")
        XCTAssertTrue(movieStars.waitForExistence(timeout: 10), "the list never showed Low Tide's stars")
        XCTAssertTrue(IOSTest.element(app, "rateWatched.stars.2001").exists, "the list leaves out the show the viewer caught up with")
        IOSTest.capture("01-rate-list", in: self)
        movieStars.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        IOSTest.settle(2)
        XCTAssertTrue(movieStars.exists, "the rated movie left the list under the finger")
        XCTAssertEqual(movieStars.value as? String, "4 out of 5 stars")
        IOSTest.capture("02-rated-in-place", in: self)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(IOSTest.wait(for: card, "exists == false", timeout: 20), "Home still asks about the rated movie")
        clearRating(of: "Low Tide", in: app)
    }

    /// The demo keeps ratings between launches, so the movie this test rated is unrated again for the next run.
    private func clearRating(of title: String, in app: XCUIApplication) {
        tab(app, "Search").tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(title)
        let result = app.cells.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        result.tap()
        let rated = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Your rating'")).firstMatch
        XCTAssertTrue(rated.waitForExistence(timeout: 30), "the rating from the row never reached the title")
        rated.tap()
        let clear = app.buttons["Clear Rating"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        clear.tap()
        XCTAssertTrue(app.buttons["Rate"].waitForExistence(timeout: 10))
    }

    func testRemoveFromContinueWatchingTakesTheCardAway() {
        let app = enterDemo()
        tab(app, "Home").tap()
        let card = app.cells.containing(NSPredicate(format: "label CONTAINS 'Deep Field'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "Deep Field is not on Home")
        card.press(forDuration: 1.2)
        let remove = app.buttons["Remove from Continue Watching"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "the card menu offers Remove from Continue Watching")
        IOSTest.capture("01-card-menu", in: self)
        remove.tap()
        XCTAssertTrue(IOSTest.wait(for: card, "exists == false", timeout: 20), "the removed title stayed on Home")
        IOSTest.capture("02-removed", in: self)
    }
}
