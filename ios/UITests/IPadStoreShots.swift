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

    func testCapturesTheStoreScreens() {
        let app = IPadDemo.enter(extraEnvironment: ["CRUCIBLE_PRO": "lifetime"])
        XCUIDevice.shared.orientation = .landscapeLeft
        IOSTest.settle(4)
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

        press(app, "f")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Command-F did not open Search")
        field.typeText("hal\n")
        IOSTest.settle(4)
        IOSTest.capture("06-search", in: self)

        press(app, "s", [.command, .shift], settle: 8)
        IOSTest.capture("07-stats", in: self)

        press(app, "y", settle: 5)
        IOSTest.capture("08-history", in: self)
    }
}
