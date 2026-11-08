import XCTest

/// Connects the demo's stand-in Seerr on Apple TV in one click (Crucible finds it next to the server), then requests a
/// watchlist title the server lacks and finds it under Requests.
@MainActor
final class SeerrTests: TVTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launchIntoDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CRUCIBLE_UITEST"] = "1"
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("CRUCIBLE_") && key != "CRUCIBLE_MOCK" && key != "CRUCIBLE_DEMO_URL" {
            app.launchEnvironment[key] = value
        }
        app.launchEnvironment["CRUCIBLE_FRESH"] = "1"
        app.launch()
        XCTAssertTrue(AppNavigation.element(app, "onboarding.signIn").waitForExistence(timeout: 30), "Welcome never appeared")
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

    private func openYou(_ app: XCUIApplication) {
        AppNavigation.selectTab("You", in: app)
        XCTAssertTrue(AppNavigation.element(app, "you.demo").waitForExistence(timeout: 15), "the Demo library row is missing")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.demo"), "the Demo library row should lead the list")
        TVTest.settle()
    }

    private func connect(_ app: XCUIApplication) {
        openYou(app)
        YouNavigation.moveFocus(app, to: "you.seerr", limit: 30)
        TVTest.settle(1)
        TVTest.capture("00-you-integrations", in: self)
        TVTest.remote.press(.select)
        TVTest.settle()
        let connect = YouNavigation.row(app, "seerr.connect")
        XCTAssertTrue(connect.waitForExistence(timeout: 30), "Crucible did not find the demo's Seerr")
        TVTest.settle(1)
        if !connect.hasFocus { YouNavigation.moveFocusUp(app, to: "seerr.connect", limit: 4) }
        TVTest.capture("01-seerr-found", in: self)
        TVTest.remote.press(.select)
        XCTAssertTrue(YouNavigation.row(app, "seerr.user").waitForExistence(timeout: 30), "connecting never showed the Seerr account")
        XCTAssertTrue(YouNavigation.row(app, "seerr.requests").exists, "a connected Seerr offers no Requests")
        TVTest.settle(1)
        TVTest.capture("02-seerr-connected", in: self)
    }

    func testRequestingAWatchlistTitleFromTheCouch() {
        let app = launchIntoDemo()
        connect(app)
        TVTest.remote.press(.menu)
        TVTest.settle(1.5)
        YouNavigation.moveFocusUp(app, to: "you.watchlist", limit: 30)
        TVTest.remote.press(.select)
        let missing = AppNavigation.element(app, "grid.demo-night-train")
        XCTAssertTrue(missing.waitForExistence(timeout: 30), "the watchlist lists no Night Train")
        TVTest.settle(1)
        for _ in 0..<6 where !missing.hasFocus {
            TVTest.remote.press(.right)
            TVTest.settle(0.4)
        }
        XCTAssertTrue(missing.hasFocus, "focus never reached Night Train")
        XCTAssertTrue(IOSLikeLabel.contains(app, "Not on your server"), "the watchlist card does not say the server lacks the title")
        TVTest.capture("02a-watchlist-states", in: self)
        TVTest.remote.press(.select)
        let submit = YouNavigation.row(app, "seerr.request.submit")
        XCTAssertTrue(submit.waitForExistence(timeout: 30), "Request offers no Request button")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "seerr.request.submit"), "focus should rest on Request")
        TVTest.capture("03-request", in: self)
        TVTest.remote.press(.select)
        XCTAssertTrue(YouNavigation.row(app, "seerr.request.watchlisted").waitForExistence(timeout: 30), "requesting did not say the title stays on the watchlist")
        XCTAssertTrue(IOSLikeLabel.contains(app, "Downloading 35%"), "the requested title does not show its download")
        TVTest.capture("04-requested", in: self)

        TVTest.remote.press(.menu)
        TVTest.settle(1)
        TVTest.remote.press(.menu)
        TVTest.settle(1.5)
        YouNavigation.moveFocus(app, to: "you.requests", limit: 6)
        TVTest.remote.press(.select)
        let train = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'seerr.requests.' AND label CONTAINS 'Night Train'")).firstMatch
        XCTAssertTrue(train.waitForExistence(timeout: 30), "Requests does not list the new request")
        TVTest.settle(1)
        TVTest.capture("05-requests", in: self)
    }
}

private enum IOSLikeLabel {
    static func contains(_ app: XCUIApplication, _ text: String) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 15)
    }
}
