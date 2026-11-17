import XCTest

/// The welcome a first library opens with, and the Trakt invitation on a title page. Every launch starts as a new install
/// (`CRUCIBLE_FRESH=1`) on the scripted store, signed in to the mock. The welcome is owed only with `CRUCIBLE_WELCOME=1` and the
/// invitation shows only with `CRUCIBLE_TRAKT_INVITE=1`, so the other tests never meet them; `CRUCIBLE_TRAKT` points Trakt at the
/// mock, where nothing is connected.
@MainActor
final class WelcomeTests: TVTestCase {
    private var mockURL: String { ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"] ?? "" }

    private func launchWelcomed(pro: String) -> XCUIApplication {
        TVTest.launch(extraEnvironment: [
            "CRUCIBLE_FRESH": "1",
            "CRUCIBLE_WELCOME": "1",
            "CRUCIBLE_PRO": pro,
            "CRUCIBLE_TRAKT": mockURL,
            "CRUCIBLE_STYLE": "dark",
        ])
    }

    func testAFirstLibraryOpensWithTheWelcomeAndStartWatchingCloses() {
        let app = launchWelcomed(pro: "free")
        let start = app.buttons["welcome.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 60), "the welcome never appeared over the first library")
        XCTAssertTrue(TVTest.waitForFocus(start), "Start Watching must take the focus")
        XCTAssertTrue(AppNavigation.element(app, "welcome.standing").label.hasPrefix("Free to watch"), "a free viewer is told what is free")
        XCTAssertTrue(app.buttons["welcome.trakt"].exists, "Trakt, not connected yet, is offered")
        XCTAssertFalse(app.buttons["welcome.pro"].exists, "the Pro week ahead is the offer, not the paywall")
        TVTest.settle(1.0)
        TVTest.capture("01-welcome-free", in: self)

        TVTest.remote.press(.select)
        XCTAssertTrue(TVTest.waitForNoElement(start), "Start Watching must close the welcome")
        XCTAssertTrue(AppNavigation.firstElement(app, prefix: AppNavigation.homeCardPrefix).waitForExistence(timeout: 30), "Home must be under the welcome")

        app.terminate()
        let again = TVTest.launch(extraEnvironment: ["CRUCIBLE_PRO": "free", "CRUCIBLE_STYLE": "dark"])
        XCTAssertTrue(AppNavigation.firstElement(again, prefix: AppNavigation.homeCardPrefix).waitForExistence(timeout: 60), "Home never showed a card")
        TVTest.settle(2.5)
        XCTAssertFalse(again.buttons["welcome.start"].exists, "the welcome is shown once per install")
    }

    func testABuyerIsThankedAndMenuClosesTheWelcome() {
        let app = launchWelcomed(pro: "lifetime")
        let start = app.buttons["welcome.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 60), "the welcome never appeared over the first library")
        XCTAssertTrue(AppNavigation.element(app, "welcome.standing").label.hasPrefix("Crucible Pro is yours"), "a buyer is thanked")
        XCTAssertFalse(app.buttons["welcome.pro"].exists, "a buyer is never offered Pro")
        TVTest.settle(1.0)
        TVTest.capture("02-welcome-pro", in: self)

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForNoElement(start), "Menu must close the welcome")
        XCTAssertTrue(app.tabBars.firstMatch.exists, "Menu must leave the main UI up, not the app")
    }

    func testConnectTraktOnTheWelcomeOpensTraktsPitch() {
        let app = launchWelcomed(pro: "free")
        let trakt = app.buttons["welcome.trakt"]
        XCTAssertTrue(trakt.waitForExistence(timeout: 60), "the welcome never offered Trakt")
        XCTAssertTrue(TVTest.waitForFocus(app.buttons["welcome.start"]))
        TVTest.remote.press(.right)
        XCTAssertTrue(TVTest.waitForFocus(trakt), "Right must reach Connect Trakt")
        TVTest.remote.press(.select)
        XCTAssertTrue(AppNavigation.element(app, "trakt.connect").waitForExistence(timeout: 10), "Connect Trakt must open Trakt's pitch with its Connect row")
        TVTest.settle(0.8)
        TVTest.capture("03-welcome-trakt-pitch", in: self)

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(trakt), "Menu must return to the welcome, on Connect Trakt")
    }

    func testATitlePageInvitesToTraktAndNotNowPutsTheInvitationAway() {
        let app = TVTest.launch(extraEnvironment: [
            "CRUCIBLE_FRESH": "1",
            "CRUCIBLE_TRAKT": mockURL,
            "CRUCIBLE_TRAKT_INVITE": "1",
            "CRUCIBLE_STYLE": "dark",
        ])
        XCTAssertTrue(AppNavigation.firstElement(app, prefix: AppNavigation.homeCardPrefix).waitForExistence(timeout: 60), "Home never showed a card")
        TVTest.settle(1.5)
        AppNavigation.selectTab("Movies", in: app)
        XCTAssertTrue(AppNavigation.move(app, .down, untilFocusHasPrefix: "tv.library.media."), "focus never reached a movie")
        TVTest.remote.press(.select)
        XCTAssertTrue(app.buttons["detail.action.primary"].waitForExistence(timeout: 20), "the movie's page never appeared")
        TVTest.settle(1.0)

        XCTAssertTrue(AppNavigation.move(app, .down, untilFocusHasPrefix: "detail.traktInvite."), "the invitation never took focus")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.traktInvite.connect"), "coming down onto the invitation lands on Connect Trakt")
        TVTest.settle(0.8)
        TVTest.capture("04-title-invitation", in: self)

        TVTest.remote.press(.select)
        XCTAssertTrue(AppNavigation.element(app, "trakt.connect").waitForExistence(timeout: 10), "Connect Trakt must open Trakt's pitch")
        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.traktInvite.connect"), "Menu must come back to the invitation")

        TVTest.remote.press(.right)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.traktInvite.notNow"))
        TVTest.remote.press(.select)
        XCTAssertTrue(TVTest.waitForNoElement(app.buttons["detail.traktInvite.connect"]), "Not Now must take the invitation away")
        XCTAssertTrue(AppNavigation.move(app, .down, untilFocusHasPrefix: "detail.", limit: 1), "focus must stay on the page")
        XCTAssertFalse(AppNavigation.focusedIdentifier(app).hasPrefix("detail.action."), "focus must move on to what followed, not back to the top")
        TVTest.settle(0.8)
        TVTest.capture("05-invitation-put-away", in: self)
    }
}
