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
