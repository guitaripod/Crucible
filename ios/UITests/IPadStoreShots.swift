import XCTest

/// The App Store's 13-inch iPad screens, captured in landscape from the built-in demo with the sidebar showing, as an owner of
/// Crucible Pro so no offer covers a screen. Runs only on an iPad with `CRUCIBLE_STORE_SHOTS=1` (set by `marketing/store/shoot-ipad.sh`);
/// the captures are composed by `marketing/store/compose.py`.
@MainActor
final class IPadStoreShots: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CRUCIBLE_STORE_SHOTS"] == "1", "store captures only")
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func press(_ app: XCUIApplication, _ key: String, _ flags: XCUIElement.KeyModifierFlags = .command, settle: TimeInterval = 3) {
        app.typeKey(key, modifierFlags: flags)
        IOSTest.settle(settle)
        XCTAssertEqual(app.state, .runningForeground, "the app stopped after \(key)")
    }

    /// Opens the poster called `title`; the last match is the library grid's, after a Continue banner or a Recently Watched rail.
    private func open(_ title: String, in app: XCUIApplication) {
        let matches = app.cells.containing(NSPredicate(format: "label CONTAINS %@", title))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 60), "\(title) is not on screen")
        let cell = matches.allElementsBoundByIndex.last ?? matches.firstMatch
        cell.tap()
        XCTAssertTrue(IPadDemo.backButton(app).waitForExistence(timeout: 30), "\(title) did not open")
        IOSTest.settle(4)
    }

    /// Brings back the player's controls and taps its close button.
    private func closePlayer(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        IOSTest.settle(1)
        let close = ["Close", "Done", "Dismiss"].lazy.map { app.buttons[$0].firstMatch }.first { $0.exists }
        XCTAssertNotNil(close, "the player has no close button")
        close?.tap()
        XCTAssertTrue(IOSTest.wait(for: IPadDemo.backButton(app), "exists == true", timeout: 20), "the player did not close")
        IOSTest.settle(2)
    }

    /// Drags the content column (right of the sidebar) up by half the screen.
    private func scrollContent(_ app: XCUIApplication) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.75))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.3)))
        IOSTest.settle(1)
    }

    /// Opens You › Settings › Integrations from the sidebar.
    private func openIntegrations(_ app: XCUIApplication) {
        guard let you = IPadDemo.libraryEntry(app, ["You"]) else {
            XCTFail("the sidebar has no You")
            return
        }
        you.tap()
        IOSTest.settle(2)
        let settingsRow = IOSTest.element(app, "you.settings")
        for _ in 0..<6 where !settingsRow.isHittable {
            scrollContent(app)
        }
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 20), "You has no Settings row")
        settingsRow.tap()
        let settings = app.collectionViews["settings.root"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "Settings did not open")
        let category = IOSTest.element(app, "settings.category.integrations")
        for _ in 0..<4 where !category.isHittable {
            settings.swipeUp()
        }
        XCTAssertTrue(category.waitForExistence(timeout: 20), "Settings has no Integrations")
        category.tap()
    }

    /// Taps `destination` in Integrations, then its Connect, waits for the account it signs in to and goes back.
    private func connect(_ destination: String, button: String, account: String, in app: XCUIApplication) {
        let row = IOSTest.element(app, destination)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Integrations has no \(destination)")
        row.tap()
        let connect = IOSTest.element(app, button)
        XCTAssertTrue(connect.waitForExistence(timeout: 30), "\(destination) offers no Connect")
        connect.tap()
        XCTAssertTrue(IOSTest.element(app, account).waitForExistence(timeout: 60), "\(destination) never connected")
        IOSTest.settle(2)
        IPadDemo.backButton(app).tap()
        IOSTest.settle(2)
    }

    /// Connects the demo's stand-in Trakt and Seerr, so the screens show what both add: Trakt's score on a title, Everything in
    /// Statistics and Seerr's titles in Search.
    private func connectIntegrations(_ app: XCUIApplication) {
        openIntegrations(app)
        connect("settings.dest.trakt", button: "trakt.connect", account: "trakt.profile", in: app)
        connect("settings.dest.seerr", button: "seerr.connect", account: "seerr.user", in: app)
        press(app, "1", settle: 4)
        XCTAssertTrue(IOSTest.wait(for: IPadDemo.homeTitle(app), "exists == true", timeout: 30), "Home did not come back")
    }

    func testCapturesTheStoreScreens() {
        let app = IPadDemo.enter(extraEnvironment: ["CRUCIBLE_PRO": "lifetime"])
        XCUIDevice.shared.orientation = .landscapeLeft
        IOSTest.settle(4)
        connectIntegrations(app)
        XCTAssertNotNil(IPadDemo.libraryEntry(app, ["Movies"]), "the sidebar is not showing")
        IOSTest.capture("01-home", in: self)

        press(app, "2", settle: 5)
        IOSTest.capture("02-library", in: self)

        open("Cold Meridian", in: app)
        IOSTest.capture("03-detail", in: self)
        press(app, "[")

        guard let shows = IPadDemo.libraryEntry(app, ["TV Shows", "Shows"]) else {
            XCTFail("the sidebar has no TV Shows library")
            return
        }
        shows.tap()
        IOSTest.settle(4)
        open("The Salt Road", in: app)
        app.collectionViews.firstMatch.swipeUp(velocity: .slow)
        app.collectionViews.firstMatch.swipeUp(velocity: .slow)
        IOSTest.settle(2)
        IOSTest.capture("04-show", in: self)

        press(app, " ", [], settle: 2)
        let skip = app.buttons["Skip Intro"]
        XCTAssertTrue(skip.waitForExistence(timeout: 45), "the episode never offered Skip Intro")
        IOSTest.settle(4)
        IOSTest.capture("05-player", in: self)
        closePlayer(app)

        press(app, "[")
        open("Paper Lanterns", in: app)
        let accept = app.buttons["Skip Them"]
        XCTAssertTrue(accept.waitForExistence(timeout: 30), "Paper Lanterns never offered Essentials")
        for _ in 0..<3 where accept.frame.maxY > app.frame.height * 0.8 {
            app.collectionViews.firstMatch.swipeUp(velocity: .slow)
            IOSTest.settle(1)
        }
        IOSTest.settle(2)
        IOSTest.capture("04c-essentials", in: self)
        press(app, "[")

        press(app, "f")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Command-F did not open Search")
        field.typeText("hal\n")
        IOSTest.settle(4)
        IOSTest.capture("06-search", in: self)
        field.tap()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("orchard\n")
        IOSTest.settle(4)
        IOSTest.capture("06b-search-request", in: self)

        press(app, "s", [.command, .shift], settle: 8)
        IOSTest.capture("07-stats", in: self)

        press(app, "y", settle: 5)
        IOSTest.capture("08-history", in: self)
    }
}
