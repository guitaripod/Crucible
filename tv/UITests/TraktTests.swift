import XCTest

/// Connects Trakt in the demo through the real focus engine: the demo's stand-in Trakt approves the code by itself, the link
/// screen goes back to Settings › Integrations › Trakt with the account, and a title's page gains the ratings strip and
/// Check In.
@MainActor
final class TraktTests: TVTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A "wants to open Crucible" prompt left on screen by an earlier link would keep focus off the app, so it goes first.
    private func dismissLeftoverPrompt() {
        let board = XCUIApplication(bundleIdentifier: "com.apple.PineBoard")
        for _ in 0..<3 where board.buttons.matching(NSPredicate(format: "label == 'Cancel'")).firstMatch.exists {
            TVTest.remote.press(.menu)
            TVTest.settle(1)
        }
    }

    private func launchIntoDemo() -> XCUIApplication {
        dismissLeftoverPrompt()
        let app = XCUIApplication()
        app.launchEnvironment["CRUCIBLE_UITEST"] = "1"
        let environment = ProcessInfo.processInfo.environment
        for (key, value) in environment where key.hasPrefix("CRUCIBLE_") && key != "CRUCIBLE_MOCK" && key != "CRUCIBLE_DEMO_URL" {
            app.launchEnvironment[key] = value
        }
        app.launchEnvironment["CRUCIBLE_FRESH"] = "1"
        app.launch()
        let signIn = AppNavigation.element(app, "onboarding.signIn")
        XCTAssertTrue(signIn.waitForExistence(timeout: 30), "Welcome never appeared")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "onboarding.signIn"))
        TVTest.settle()
        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "onboarding.demo"), "Down from Sign in should reach Try the demo")
        TVTest.remote.press(.select)
        XCTAssertTrue(AppNavigation.element(app, "demo.intro.start").waitForExistence(timeout: 90), "the intro never appeared")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "demo.intro.start"))
        TVTest.settle(1.5)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60), "the main UI never appeared")
        XCTAssertTrue(AppNavigation.firstElement(app, prefix: AppNavigation.homeCardPrefix).waitForExistence(timeout: 60), "Home never showed a card")
        TVTest.settle(1.5)
        return app
    }

    /// The demo's You tab leads with the Demo library row, so focus starts there.
    private func openYou(_ app: XCUIApplication) {
        AppNavigation.selectTab("You", in: app)
        XCTAssertTrue(AppNavigation.element(app, "you.demo").waitForExistence(timeout: 15), "the Demo library row is missing")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.demo"), "the Demo library row should lead the list")
        TVTest.settle()
    }

    private func connect(_ app: XCUIApplication) {
        openYou(app)
        YouNavigation.moveFocus(app, to: "you.trakt", limit: 28)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.trakt"), "You has no Trakt row")
        TVTest.remote.press(.select)
        TVTest.settle()
        XCTAssertTrue(YouNavigation.row(app, "trakt.connect").waitForExistence(timeout: 15), "Trakt offers no Connect")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "trakt.connect"), "focus should rest on Connect")
        TVTest.capture("01-trakt-before-connecting", in: self)
        TVTest.remote.press(.select)
        XCTAssertTrue(AppNavigation.element(app, "trakt.qr").waitForExistence(timeout: 15), "the link screen never showed its QR code")
        TVTest.settle(0.5)
        TVTest.capture("02-trakt-link", in: self)
        XCTAssertTrue(YouNavigation.row(app, "trakt.profile").waitForExistence(timeout: 30), "the demo's approval never connected Trakt")
        TVTest.settle(1)
        TVTest.capture("03-trakt-connected", in: self)
    }

    func testConnectingTraktWithTheCode() {
        let app = launchIntoDemo()
        connect(app)
        XCTAssertTrue(YouNavigation.row(app, "trakt.scrobble").exists, "Scrobble Playback is missing")
        YouNavigation.moveFocus(app, to: "trakt.scrobble")
        let before = YouNavigation.row(app, "trakt.scrobble").value as? String
        TVTest.remote.press(.select)
        TVTest.settle(0.5)
        XCTAssertNotEqual(YouNavigation.row(app, "trakt.scrobble").value as? String, before, "selecting Scrobble Playback did not flip it")
        TVTest.remote.press(.select)
    }

    /// With Trakt connected Statistics gains a source menu beside the ranges: Everything holds the show and the two films the
    /// demo's Trakt history has from elsewhere, which Plex alone does not, while the plays Crucible sent to Trakt are not
    /// counted twice.
    func testStatisticsBringInEverythingTraktKnows() {
        let app = launchIntoDemo()
        connect(app)
        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.trakt"), "Menu from Trakt should return to its You row")
        YouNavigation.moveFocusUp(app, to: "you.statistics", limit: 28)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.collectionViews["stats.collection"].waitForExistence(timeout: 90), "the statistics page never appeared")
        TVTest.settle(2)
        if !AppNavigation.focusedIdentifier(app).hasPrefix("stats.") { TVTest.remote.press(.down) }
        let source = app.buttons["stats.source"]
        XCTAssertTrue(source.waitForExistence(timeout: 30), "Statistics offers no source menu with Trakt connected")
        for _ in 0..<6 where !source.hasFocus { TVTest.remote.press(.right); TVTest.settle(0.4) }
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "stats.source"), "focus never reached the source menu")
        choose("Everything", on: source, in: app)
        XCTAssertEqual(source.value as? String, "Everything you watched, from Trakt")
        let everythingShows = tile(app, "Shows")
        let everythingMovies = tile(app, "Movies")
        TVTest.capture("05-statistics-everything", in: self)

        choose("Plex", on: source, in: app)
        XCTAssertTrue(
            waitForLabel(of: tileElement(app, "Shows"), containing: ", \(everythingShows - 1)", timeout: 30),
            "Plex alone does not drop the show watched elsewhere"
        )
        XCTAssertEqual(tile(app, "Shows"), everythingShows - 1, "a show partly watched elsewhere is one show in Everything")
        XCTAssertEqual(tile(app, "Movies"), everythingMovies - 2, "Everything adds the two films watched elsewhere")
        XCTAssertEqual(source.value as? String, "Plex history only")
        TVTest.settle(1)
        TVTest.capture("07-statistics-plex", in: self)
    }

    /// Picks `option` from the source menu: Plex is its first item and Everything its second.
    private func choose(_ option: String, on source: XCUIElement, in app: XCUIApplication) {
        let shown = source.value as? String
        guard shown != (option == "Plex" ? "Plex history only" : "Everything you watched, from Trakt") else { return }
        TVTest.remote.press(.select)
        TVTest.settle(1)
        TVTest.capture("06-statistics-source-menu", in: self)
        for _ in 0..<2 {
            TVTest.remote.press(.up)
            TVTest.settle(0.5)
        }
        if option == "Everything" { TVTest.remote.press(.down); TVTest.settle(0.5) }
        TVTest.remote.press(.select)
        TVTest.settle(2)
    }

    private func waitForLabel(of element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
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

    /// Trakt's score sits on the hero's meta line beside Plex's own rating instead of a strip of its own.
    func testAConnectedTitleShowsTraktBesidePlexsRatingAndCheckIn() {
        let app = launchIntoDemo()
        connect(app)
        AppNavigation.openFromOutside("crucible://item/1001?type=movie", in: self)
        XCTAssertTrue(AppNavigation.detailPrimary(app).waitForExistence(timeout: 30), "the detail screen never appeared")
        let hero = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", ".*Trakt [0-9]+%.*")).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 30), "the hero's meta line has no Trakt score")
        XCTAssertFalse(AppNavigation.element(app, "detail.traktScores").exists, "the separate ratings strip is gone")
        TVTest.settle(1)
        TVTest.capture("04-detail-inline-ratings", in: self)
        let checkIn = AppNavigation.element(app, "detail.action.checkIn")
        XCTAssertTrue(checkIn.waitForExistence(timeout: 10), "the action row has no Check In")
    }
}
