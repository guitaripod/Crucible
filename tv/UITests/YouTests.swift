import XCTest

/// Navigation helpers shared by the You and Settings UI tests.
@MainActor
enum YouNavigation {
    /// Opens the You tab (always last); selecting a tab hands focus to its first row, which is Switch Profile for an account in a
    /// Plex Home (the mock's plex.tv has one) and Watch History otherwise.
    @discardableResult
    static func openYouTab(_ app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        TVTest.settle()
        AppNavigation.selectTab("You", in: app)
        let first = row(app, "you.history")
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !["you.history", "you.switchProfile"].contains(AppNavigation.focusedIdentifier(app)) {
            TVTest.settle(0.5)
        }
        XCTAssertTrue(["you.history", "you.switchProfile"].contains(AppNavigation.focusedIdentifier(app)), "the You tab's first row never took focus")
        TVTest.settle()
        return first
    }

    static func row(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Presses Down until the row with `identifier` has focus (at most `limit` presses).
    static func moveFocus(_ app: XCUIApplication, to identifier: String, limit: Int = 16) {
        for _ in 0..<limit {
            let target = row(app, identifier)
            if target.exists, target.hasFocus { return }
            TVTest.remote.press(.down)
            TVTest.settle(0.3)
        }
        XCTAssertTrue(row(app, identifier).hasFocus, "focus never reached \(identifier)")
    }

    /// Presses Up until the row with `identifier` has focus (at most `limit` presses).
    static func moveFocusUp(_ app: XCUIApplication, to identifier: String, limit: Int = 16) {
        for _ in 0..<limit {
            let target = row(app, identifier)
            if target.exists, target.hasFocus { return }
            TVTest.remote.press(.up)
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
final class YouTests: TVTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testYouTabShowsProfileRowsAndYearCard() {
        let app = TVTest.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        TVTest.settle(2)
        AppNavigation.selectTab("You", in: app)
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

    func testProfilePanelIsNotADeadFocusStopWithoutVoiceOver() {
        let app = TVTest.launch()
        YouNavigation.openYouTab(app)
        TVTest.remote.press(.left)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.yearCard", timeout: 20))
        TVTest.remote.press(.up)
        TVTest.settle(1)
        XCTAssertFalse(YouNavigation.row(app, "you.profile").hasFocus)
    }

    func testProfilePanelIsReachableByFocusWhileVoiceOverRuns() {
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_VOICEOVER": "1"])
        YouNavigation.openYouTab(app)
        TVTest.remote.press(.left)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.yearCard", timeout: 20))
        TVTest.remote.press(.up)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.profile"), "VoiceOver follows the focus engine, so the profile must be a focus stop")
        TVTest.settle()
        XCTAssertTrue(YouNavigation.row(app, "you.profile").label.hasPrefix("Marcus, Marcus-PC"))
        TVTest.capture("01-profile-panel-focused", in: self)
        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.yearCard"))
    }

    func testAProfileWithAPINAsksForItAndTheAppComesBackAsThatProfile() {
        let mock = ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"] ?? ""
        _ = URL(string: mock + "/mock/tokens?clear=1").flatMap(TVTest.fetch)
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_PLEXTV": mock])
        YouNavigation.openYouTab(app)
        XCTAssertTrue(YouNavigation.row(app, "you.switchProfile").waitForExistence(timeout: 20), "an account in a Plex Home offers Switch Profile")
        YouNavigation.moveFocusUp(app, to: "you.switchProfile")
        TVTest.remote.press(.select)
        XCTAssertTrue(YouNavigation.row(app, "profiles.sam-32c9").waitForExistence(timeout: 20), "the Home's profiles are listed")
        TVTest.settle(1)
        TVTest.capture("01-profiles", in: self)
        YouNavigation.moveFocus(app, to: "profiles.sam-32c9")
        TVTest.remote.press(.select)
        enterPIN("0000", in: app)
        XCTAssertTrue(app.alerts.firstMatch.staticTexts["That PIN isn\u{2019}t right."].waitForExistence(timeout: 15), "a wrong PIN is refused and asked again")
        TVTest.capture("02-wrong-pin", in: self)
        enterPIN("1234", in: app)
        XCTAssertTrue(waitForServerToken("mock-server-sam-32c9", timeout: 60), "the app talks to the server as Sam")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60), "the app comes back after switching")
        YouNavigation.openYouTab(app)
        let switchRow = YouNavigation.row(app, "you.switchProfile")
        XCTAssertTrue(switchRow.waitForExistence(timeout: 20))
        XCTAssertTrue(switchRow.label.contains("Sam") || (switchRow.value as? String ?? "").contains("Sam"), "You names the profile watching now, not \(switchRow.label)")
        TVTest.capture("03-switched-to-sam", in: self)
    }

    /// Opens the keyboard from the PIN prompt's field, types `pin`, leaves the keyboard and presses Switch.
    private func enterPIN(_ pin: String, in app: XCUIApplication) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "a protected profile asks for its PIN")
        XCTAssertTrue(alert.secureTextFields.firstMatch.exists || alert.textFields.firstMatch.exists, "the PIN prompt has a field")
        TVTest.settle(1)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "Select on the PIN field opened no keyboard")
        TVTest.settle(1.5)
        app.typeText(pin)
        TVTest.settle(1)
        for _ in 0..<8 where AppNavigation.focusedElement(app).label.lowercased() != "done" {
            TVTest.remote.press(.down)
            TVTest.settle(0.4)
        }
        XCTAssertEqual(AppNavigation.focusedElement(app).label.lowercased(), "done", "focus never reached the keyboard's done button")
        TVTest.remote.press(.select)
        TVTest.settle(1)
        for direction in [XCUIRemote.Button.down, .right, .left, .up] where AppNavigation.focusedElement(app).label != "Switch" {
            TVTest.remote.press(direction)
            TVTest.settle(0.5)
        }
        XCTAssertEqual(AppNavigation.focusedElement(app).label, "Switch", "focus never reached Switch")
        TVTest.remote.press(.select)
        TVTest.settle(1)
    }

    private func waitForServerToken(_ token: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let base = ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"], let url = URL(string: base + "/mock/tokens"),
               let data = TVTest.fetch(url),
               let tokens = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tokens"] as? [String], tokens.contains(token) {
                return true
            }
            TVTest.settle(1)
        }
        return false
    }

    func testReturningFromSubScreensDoesNotReloadTheHistoryHeadline() throws {
        let app = TVTest.launch()
        YouNavigation.openYouTab(app)
        XCTAssertTrue(YouNavigation.row(app, "you.history").label.contains("Halcyon") || waitForHeadline(app))
        TVTest.settle(2)
        let before = try historyHeadlineRequests()
        for _ in 0..<3 {
            YouNavigation.openRow(app, "you.playback")
            XCTAssertTrue(YouNavigation.row(app, "playback.streamingQuality").waitForExistence(timeout: 10))
            TVTest.remote.press(.menu)
            XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.playback"))
            TVTest.settle(1)
        }
        XCTAssertEqual(try historyHeadlineRequests(), before, "popping back within a minute must not refetch the headline")
    }

    private func waitForHeadline(_ app: XCUIApplication) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS 'Halcyon'")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: YouNavigation.row(app, "you.history"))
        return XCTWaiter().wait(for: [expectation], timeout: 20) == .completed
    }

    private func historyHeadlineRequests() throws -> Int {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"])
        var components = try XCTUnwrap(URLComponents(string: base + "/mock/requests"))
        components.queryItems = [URLQueryItem(name: "contains", value: "history/all?X-Plex-Container-Start=0&X-Plex-Container-Size=1&")]
        let data = try XCTUnwrap(TVTest.fetch(try XCTUnwrap(components.url)))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Int]
        return try XCTUnwrap(object?["count"])
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
