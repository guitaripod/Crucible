import XCTest

/// What to Watch and a described Previously On on Apple TV, through the real focus engine against the mock Plex
/// server. The hosted model is scripted (`CRUCIBLE_BRAIN=ok`) unless the run names another: `CRUCIBLE_BRAIN=live`
/// asks Crucible's real model over the network, which is the end-to-end check.
@MainActor
final class WhatToWatchTests: TVTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    private var brain: String {
        ProcessInfo.processInfo.environment["CRUCIBLE_BRAIN"] ?? "ok"
    }

    private func launch(pro: String, extraEnvironment: [String: String] = [:]) {
        var environment = ["CRUCIBLE_PRO": pro, "CRUCIBLE_BRAIN": brain]
        environment.merge(extraEnvironment) { _, new in new }
        app = TVTest.launch(extraEnvironment: environment)
    }

    private var focusedIdentifier: String {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch.identifier
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var firstPick: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'watch.pick.'")).firstMatch
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1, settle: TimeInterval = 0.5) {
        for _ in 0..<times {
            TVTest.remote.press(button)
            TVTest.settle(settle)
        }
    }

    /// Moves focus from the top of Home to the What to Watch tile near the end of Recently Added.
    private func focusTile() {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60))
        TVTest.settle(2)
        for _ in 0..<10 where !focusedIdentifier.hasPrefix("home.card.recentlyAdded.") {
            press(.down)
        }
        XCTAssertTrue(focusedIdentifier.hasPrefix("home.card.recentlyAdded."), "focus never reached Recently Added, it is on \(focusedIdentifier)")
        for _ in 0..<40 where focusedIdentifier != "home.whatToWatch" {
            press(.right, settle: 0.25)
        }
        TVTest.settle(0.8)
        XCTAssertEqual(focusedIdentifier, "home.whatToWatch", "Recently Added has no What to Watch tile")
    }

    private func labelled(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Presses `button` until the element named `identifier` holds focus. A button inside a cell is asked itself:
    /// the first focused element of the tree can be the cell around it, which has no identifier.
    private func focus(_ identifier: String, pressing button: XCUIRemote.Button, atMost presses: Int = 10) {
        for _ in 0..<presses where !isFocused(identifier) {
            press(button, settle: 0.35)
        }
        XCTAssertTrue(isFocused(identifier), "focus never reached \(identifier), it is on \(focusedIdentifier)")
    }

    private func isFocused(_ identifier: String) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND identifier == %@", identifier)).firstMatch.exists
    }

    func testTheTileAsksAndAnExampleBecomesPicks() {
        launch(pro: "lifetime")
        focusTile()
        TVTest.capture("01-tile-focused", in: self)
        press(.select)
        XCTAssertTrue(element("watch.example.0").waitForExistence(timeout: 10), "Select on the tile opens nothing")
        XCTAssertTrue(element("watch.own").exists)
        TVTest.settle(1)
        XCTAssertTrue(isFocused("watch.example.0"), "the first example should hold focus")
        TVTest.capture("02-ask", in: self)
        focus("watch.example.1", pressing: .down)
        press(.select)
        XCTAssertTrue(firstPick.waitForExistence(timeout: 120), "no pick came back")
        TVTest.settle(2)
        TVTest.capture("03-picks", in: self)
        XCTAssertTrue(focusedIdentifier.hasPrefix("watch.pick."), "focus is not on a pick but on \(focusedIdentifier)")
        press(.right)
        TVTest.capture("04-second-pick-focused", in: self)
        press(.select)
        let detail = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'detail.'")).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 30), "a pick opens no page")
        press(.menu, settle: 1.5)
        XCTAssertTrue(firstPick.waitForExistence(timeout: 10), "Menu does not return to the picks")
        press(.menu, settle: 1.5)
        XCTAssertTrue(element("watch.example.0").waitForExistence(timeout: 10), "Menu on the picks does not return to asking")
        TVTest.capture("05-back-on-asking", in: self)
    }

    func testTypingYourOwnAsksForIt() {
        launch(pro: "lifetime", extraEnvironment: ["CRUCIBLE_OPEN": "whattowatch"])
        XCTAssertTrue(element("watch.own").waitForExistence(timeout: 60), "the ask screen never opened")
        TVTest.settle(1.5)
        focus("watch.own", pressing: .down)
        press(.select)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10), "Say or Type Your Own opens no field")
        TVTest.settle(1)
        press(.select, settle: 2)
        app.typeText("a quiet film")
        TVTest.settle(1)
        TVTest.capture("06-typing", in: self)
        press(.down, times: 3, settle: 0.3)
        press(.select, settle: 1.5)
        XCTAssertTrue(labelled("Suggest").waitForExistence(timeout: 10), "the keyboard's Done does not return to the request")
        let suggestHasFocus = { self.app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND label == 'Suggest'")).firstMatch.exists }
        if !suggestHasFocus() { press(.down, settle: 0.4) }
        if !suggestHasFocus() { press(.right, settle: 0.4) }
        TVTest.capture("06b-request-entered", in: self)
        XCTAssertTrue(suggestHasFocus(), "focus never reached Suggest, it is on \(focusedIdentifier)")
        press(.select)
        XCTAssertTrue(firstPick.waitForExistence(timeout: 120), "no pick came back for a typed request")
        TVTest.settle(1.5)
        TVTest.capture("07-picks-for-typed", in: self)
        XCTAssertTrue(labelled("a quiet film").exists, "the picks do not say what was asked")
    }

    func testWithoutProAskingOpensThePaywallThatNamesIt() {
        launch(pro: "free", extraEnvironment: ["CRUCIBLE_FRESH": "1", "CRUCIBLE_OPEN": "whattowatch"])
        XCTAssertTrue(element("watch.example.0").waitForExistence(timeout: 60), "the ask screen never opened")
        TVTest.settle(1.5)
        focus("watch.example.0", pressing: .down)
        press(.select)
        XCTAssertTrue(element("paywall.buy").waitForExistence(timeout: 30), "asking without Crucible Pro did not open the paywall")
        TVTest.settle(1.5)
        TVTest.capture("08-paywall", in: self)
        XCTAssertTrue(labelled("What to Watch is part of Crucible Pro").exists, "the paywall does not say why it opened")
    }

    func testAShowWithoutACompanionReadsItsDescriptionsAndWritesARecap() {
        launch(pro: "lifetime", extraEnvironment: ["CRUCIBLE_OPEN_LINK": "crucible://item/2005?type=show"])
        XCTAssertTrue(element("detail.action.primary").waitForExistence(timeout: 60), "the show page never opened")
        TVTest.settle(2)
        focus("detail.action.primary", pressing: .down, atMost: 3)
        focus("detail.action.previouslyOn", pressing: .right)
        TVTest.capture("09-previously-on-button", in: self)
        press(.select)
        let choice = app.alerts.firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertTrue(labelled("Write a Recap").exists)
        XCTAssertTrue(labelled("Read the Descriptions").exists)
        TVTest.capture("10-previously-on-choice", in: self)
        press(.down)
        press(.select)
        let text = element("detail.synopsis.text")
        XCTAssertTrue(text.waitForExistence(timeout: 10), "Read the Descriptions shows nothing")
        TVTest.settle(1)
        TVTest.capture("11-descriptions", in: self)
        press(.menu, settle: 1.5)

        press(.select)
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        press(.select)
        XCTAssertTrue(text.waitForExistence(timeout: 120), "no recap came back")
        TVTest.settle(1)
        TVTest.capture("12-recap", in: self)
        XCTAssertTrue(labelled("From the description").exists, "the recap does not say what it draws on")
    }
}
