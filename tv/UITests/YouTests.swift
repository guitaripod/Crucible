import XCTest

/// Navigation helpers shared by the You and Settings UI tests.
@MainActor
enum YouNavigation {
    /// Opens the You tab (always last); selecting a tab hands focus to its first row.
    @discardableResult
    static func openYouTab(_ app: XCUIApplication) -> XCUIElement {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30))
        TVTest.settle()
        let count = tabBar.buttons.count
        for _ in 1..<max(count, 1) {
            TVTest.remote.press(.right)
        }
        TVTest.remote.press(.select)
        let first = row(app, "you.history")
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.history"))
        TVTest.settle()
        return first
    }

    static func row(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Presses Down until the row with `identifier` has focus (at most `limit` presses).
    static func moveFocus(_ app: XCUIApplication, to identifier: String, limit: Int = 12) {
        for _ in 0..<limit {
            if row(app, identifier).hasFocus { return }
            TVTest.remote.press(.down)
            TVTest.settle(0.3)
        }
        XCTAssertTrue(row(app, identifier).hasFocus, "focus never reached \(identifier)")
    }

    static func openRow(_ app: XCUIApplication, _ identifier: String) {
        moveFocus(app, to: identifier)
        TVTest.remote.press(.select)
        TVTest.settle()
    }
}

@MainActor
final class YouTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testYouTabShowsProfileRowsAndYearCard() {
        let app = TVTest.launch()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30))
        TVTest.settle(2)
        let count = tabBar.buttons.count
        for _ in 1..<max(count, 1) {
            TVTest.remote.press(.right)
        }
        TVTest.remote.press(.select)
        XCTAssertTrue(YouNavigation.row(app, "you.history").waitForExistence(timeout: 15))
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.history"))
        TVTest.settle(2)
        TVTest.capture("01-you-tab-first-row-focused", in: self)

        let profile = YouNavigation.row(app, "you.profile").label
        XCTAssertTrue(profile.hasPrefix("Marcus, Marcus-PC"), profile)

        TVTest.remote.press(.left)
        TVTest.settle(1.5)
        TVTest.capture("02-after-left", in: self)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.yearCard", timeout: 20), "the Year in Review card should be reachable with Left")
        TVTest.settle()
        TVTest.capture("03-year-card-focused", in: self)

        TVTest.remote.press(.right)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.history"))
        YouNavigation.moveFocus(app, to: "you.signOut")
        TVTest.settle()
        TVTest.capture("04-sign-out-focused-scrolled", in: self)
    }

    func testSignOutAsksForConfirmation() {
        let app = TVTest.launch()
        YouNavigation.openYouTab(app)
        YouNavigation.moveFocus(app, to: "you.signOut")
        TVTest.remote.press(.select)
        let alert = app.alerts["Sign Out"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        TVTest.settle()
        TVTest.capture("01-sign-out-confirmation", in: self)

        TVTest.remote.press(.menu)
        XCTAssertTrue(waitForDisappearance(of: alert))
        XCTAssertTrue(YouNavigation.row(app, "you.signOut").exists)
        XCTAssertTrue(app.tabBars.firstMatch.exists, "cancelling must keep the session")
        TVTest.settle()
        TVTest.capture("02-sign-out-cancelled", in: self)
    }

    func testStatisticsRowOpensTheStatisticsScreen() {
        let app = TVTest.launch()
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.statistics")
        XCTAssertFalse(YouNavigation.row(app, "you.history").exists, "the You list should have been replaced by the Statistics screen")
    }

    func testSettingsRowsPushSubScreensAndBackPops() {
        let app = TVTest.launch()
        YouNavigation.openYouTab(app)
        for (row, marker) in [("you.playback", "playback.streamingQuality"), ("you.libraries", "library.1"), ("you.server", "server.test"), ("you.about", "about.version")] {
            YouNavigation.openRow(app, row)
            XCTAssertTrue(YouNavigation.row(app, marker).waitForExistence(timeout: 20), "\(row) should open the screen with \(marker)")
            TVTest.remote.press(.menu)
            XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: row), "Back should return focus to \(row)")
        }
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
