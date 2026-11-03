import XCTest

/// Home's newer rows and controls on Apple TV: Rate What You Watched, Remove from Continue Watching, the Home Rows screen and
/// the settings categories built from the shared catalog.
@MainActor
final class RateAndHomeRowsTests: TVTestCase {
    private static let finished = "m:1003:Low Tide,s:2001:The Salt Road:4001"

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        AppNavigation.element(app, identifier)
    }

    /// Picks the item `steps` below the first one of the open context menu, whose items keep the order the app builds them in.
    private func pickMenuItem(_ app: XCUIApplication, steps: Int) {
        for _ in 0..<steps {
            TVTest.remote.press(.down)
            TVTest.settle(0.5)
        }
        TVTest.remote.press(.select)
    }

    /// Moves focus within an alert until its button labelled `label` has it. The alert lists each button twice, and only
    /// one of the two ever reports focus, so the focused element is read instead of the button. tvOS 26 lays the buttons
    /// out side by side and older systems stack them, so both axes are tried.
    private func focusAlertButton(_ app: XCUIApplication, _ label: String) -> Bool {
        for direction in [XCUIRemote.Button.right, .down, .left, .up] {
            if AppNavigation.focusedElement(app).label == label { return true }
            TVTest.remote.press(direction)
            TVTest.settle(0.5)
        }
        return AppNavigation.focusedElement(app).label == label
    }

    private func vanishes(_ element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func mockJSON(_ path: String) -> [String: Any]? {
        guard let base = ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"], let url = URL(string: base + path),
              let data = TVTest.fetch(url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func userRating(_ ratingKey: String) -> Double? {
        let container = mockJSON("/library/metadata/\(ratingKey)")?["MediaContainer"] as? [String: Any]
        let item = (container?["Metadata"] as? [[String: Any]])?.first
        return item?["userRating"] as? Double
    }

    func testFinishedTitlesAreAskedAboutAndRatingOneTakesItOff() {
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_FINISHED": Self.finished])
        XCTAssertTrue(AppNavigation.move(app, .down, untilFocusHasPrefix: "home.rate.", limit: 12), "focus never reached the Rate What You Watched shelf")
        let movie = element(app, "home.rate.1003")
        XCTAssertTrue(movie.waitForExistence(timeout: 10), "Rate What You Watched never showed the finished movie")
        XCTAssertTrue(element(app, "home.rate.2001").exists, "the show the viewer caught up with is asked about too")
        XCTAssertTrue(AppNavigation.move(app, .left, untilFocusHasPrefix: "home.rate.1003", limit: 4))
        TVTest.capture("01-rate-shelf", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(1.2)
        TVTest.capture("02-rating-panel", in: self)
        for _ in 0..<7 {
            TVTest.remote.press(.right)
            TVTest.settle(0.3)
        }
        TVTest.remote.press(.select)
        XCTAssertTrue(vanishes(movie), "the rated movie stayed on the shelf")
        TVTest.capture("03-after-rating", in: self)
        XCTAssertNotNil(userRating("1003"), "the rating never reached the server")
        XCTAssertTrue(element(app, "home.rate.2001").exists, "the show is still waiting for its rating")
    }

    func testNotNowTakesATitleOffTheShelf() {
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_FINISHED": Self.finished])
        XCTAssertTrue(AppNavigation.move(app, .down, untilFocusHasPrefix: "home.rate.", limit: 12))
        let show = element(app, "home.rate.2001")
        XCTAssertTrue(show.waitForExistence(timeout: 10))
        XCTAssertTrue(AppNavigation.move(app, .right, untilFocusHasPrefix: "home.rate.2001", limit: 4))
        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1.0)
        XCTAssertTrue(app.descendants(matching: .any)["Not Now"].waitForExistence(timeout: 5), "the long-press menu offers Not Now")
        TVTest.capture("01-not-now-menu", in: self)
        pickMenuItem(app, steps: 2)
        XCTAssertTrue(vanishes(show), "Not Now left the show on the shelf")
    }

    func testRemoveFromContinueWatchingDropsTheCard() {
        let app = AppNavigation.launchHome()
        let card = element(app, "home.card.continueWatching.1002")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "Deep Field is in Continue Watching")
        XCTAssertTrue(AppNavigation.move(app, .down, untilFocusHasPrefix: "home.card.continueWatching.", limit: 6))
        XCTAssertTrue(AppNavigation.move(app, .right, untilFocusHasPrefix: "home.card.continueWatching.1002", limit: 6))
        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1.0)
        XCTAssertTrue(app.descendants(matching: .any)["Remove from Continue Watching"].waitForExistence(timeout: 5), "the long-press menu offers Remove from Continue Watching")
        TVTest.capture("01-remove-menu", in: self)
        pickMenuItem(app, steps: 4)
        XCTAssertTrue(vanishes(card), "the removed title stayed in Continue Watching")
        TVTest.capture("02-removed", in: self)
    }

    func testHomeRowsTurnRecentlyAddedOff() {
        let app = TVTest.launch()
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.homeRows")
        let recent = YouNavigation.row(app, "homeRows.recentlyAdded")
        XCTAssertTrue(recent.waitForExistence(timeout: 15))
        YouNavigation.moveFocus(app, to: "homeRows.recentlyAdded")
        TVTest.remote.press(.select)
        TVTest.settle(0.6)
        XCTAssertEqual(recent.value as? String, "Off")
        TVTest.capture("01-recently-added-off", in: self)
        AppNavigation.selectTab("Home", in: app)
        TVTest.settle(2)
        XCTAssertFalse(AppNavigation.firstElement(app, prefix: "home.card.recentlyAdded.").exists, "Recently Added still shows on Home")
        TVTest.capture("02-home-without-recently-added", in: self)
        AppNavigation.selectTab("You", in: app)
        YouNavigation.openRow(app, "you.homeRows")
        YouNavigation.moveFocus(app, to: "homeRows.reset")
        TVTest.remote.press(.select)
        TVTest.settle(0.6)
        XCTAssertEqual(YouNavigation.row(app, "homeRows.recentlyAdded").value as? String, "On")
    }

    func testRemoteSettingsLiveInTheirOwnCategory() {
        let app = TVTest.launch()
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.remote")
        XCTAssertTrue(YouNavigation.row(app, "controls.skipBack").waitForExistence(timeout: 15))
        XCTAssertTrue(YouNavigation.row(app, "controls.holdRight").exists)
        TVTest.capture("01-remote-settings", in: self)
        YouNavigation.moveFocus(app, to: "controls.skipBack")
        TVTest.remote.press(.select)
        XCTAssertTrue(YouNavigation.row(app, "choice.30").waitForExistence(timeout: 10))
        YouNavigation.moveFocus(app, to: "choice.30")
        TVTest.remote.press(.select)
        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "controls.skipBack"))
        XCTAssertTrue(YouNavigation.row(app, "settings.restoreDefaults").waitForExistence(timeout: 5), "a changed category offers Restore Defaults")
        YouNavigation.moveFocus(app, to: "settings.restoreDefaults")
        TVTest.remote.press(.select)
        let alert = app.alerts["Restore Defaults?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        TVTest.capture("02-restore-defaults", in: self)
        XCTAssertTrue(focusAlertButton(app, "Restore"), "focus never reached Restore, it is on \(AppNavigation.focusedElement(app).label)")
        TVTest.remote.press(.select)
        TVTest.settle(0.8)
        XCTAssertEqual(YouNavigation.row(app, "controls.skipBack").value as? String, "10 Seconds")
    }
}
