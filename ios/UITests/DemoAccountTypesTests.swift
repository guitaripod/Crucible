import XCTest

/// Every kind of account a reviewer may ask about, inside the built-in demo on iPhone and iPad: the owner with the owner's tools, the
/// managed Kids profile, Sam's profile behind the PIN 1234, and a free install's locks with the scripted store (`CRUCIBLE_PRO=free`).
/// It also checks the way in: closing the Plex sign-in sheet hands the welcome screen back with Try the demo ready. That test asks
/// the real plex.tv for a PIN, as the sheet opens only once one has come back, so it needs the network.
@MainActor
final class DemoAccountTypesTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        IOSTest.element(app, identifier)
    }

    private func enterDemo() -> XCUIApplication {
        let app = IOSTest.launch()
        let demo = element(app, "onboarding.demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 60), "Welcome never showed Try the demo")
        demo.tap()
        let start = element(app, "demo.intro.start")
        XCTAssertTrue(start.waitForExistence(timeout: 120), "the demo intro never appeared")
        start.tap()
        XCTAssertTrue(IOSTest.wait(for: start, "exists == false OR hittable == false", timeout: 30), "the intro never closed")
        IOSTest.settle(1.5)
        return app
    }

    private func openYou(_ app: XCUIApplication) {
        let you = IOSTest.tab(app, "You")
        XCTAssertTrue(you.waitForExistence(timeout: 60), "the You tab never appeared")
        you.tap()
        IOSTest.settle(1)
    }

    /// Whether the You row `identifier` is in the list, scrolling down to it: rows below the fold are not on screen until then.
    private func hasRow(_ identifier: String, in app: XCUIApplication) -> Bool {
        let row = element(app, identifier)
        for _ in 0..<4 where !row.exists {
            app.collectionViews.firstMatch.swipeUp()
            IOSTest.settle(0.5)
        }
        return row.exists
    }

    /// Server Activity sits right above the owner's Server Dashboard, so once it is on screen the dashboard would be too.
    private func hasOwnerTools(_ app: XCUIApplication) -> Bool {
        XCTAssertTrue(hasRow("you.activity", in: app), "the You list shows Server Activity")
        return hasRow("you.dashboard", in: app)
    }

    private func switchProfile(to name: String, pin: String? = nil, in app: XCUIApplication) {
        openYou(app)
        let row = element(app, "you.switchProfile")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the demo account's Home offers Switch Profile")
        row.tap()
        let profile = element(app, "profiles.\(name)")
        XCTAssertTrue(profile.waitForExistence(timeout: 20), "the Home lists \(name)")
        profile.tap()
        if let pin { enterPIN(pin, in: app) }
    }

    private func enterPIN(_ pin: String, in app: XCUIApplication) {
        let field = app.alerts.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "a protected profile asks for its PIN")
        field.tap()
        field.typeText(pin)
        app.alerts.buttons["Switch"].tap()
    }

    private func assertWatching(_ name: String, in app: XCUIApplication) {
        openYou(app)
        XCTAssertTrue(element(app, "you.switchProfile").waitForExistence(timeout: 60), "the app came back after the switch")
        let named = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ OR value == %@", name, name)).firstMatch
        XCTAssertTrue(named.waitForExistence(timeout: 15), "You names \(name) as the profile watching")
        XCTAssertFalse(hasOwnerTools(app), "\(name) gets none of the owner's tools")
    }

    func testTheDemosHomeSwitchesToKidsAndToSamWithAPIN() {
        let app = enterDemo()
        openYou(app)
        XCTAssertTrue(element(app, "you.switchProfile").waitForExistence(timeout: 30), "the demo account's Home offers Switch Profile")
        XCTAssertTrue(hasOwnerTools(app), "the demo's owner has the Server Dashboard")
        IOSTest.capture("01-owner", in: self)

        switchProfile(to: "Kids", in: app)
        assertWatching("Kids", in: app)
        IOSTest.capture("02-kids", in: self)

        switchProfile(to: "Sam", pin: "0000", in: app)
        XCTAssertTrue(app.alerts.staticTexts["That PIN isn\u{2019}t right."].waitForExistence(timeout: 15), "a wrong PIN is refused and asked again")
        IOSTest.capture("03-wrong-pin", in: self)
        enterPIN("1234", in: app)
        assertWatching("Sam", in: app)
        IOSTest.capture("04-sam", in: self)

        switchProfile(to: "Demo", in: app)
        openYou(app)
        XCTAssertTrue(element(app, "you.switchProfile").waitForExistence(timeout: 60), "the app came back as the owner")
        IOSTest.settle(3)
        XCTAssertTrue(hasOwnerTools(app), "back as the owner, the owner's tools return")
    }

    func testPreviewingTheFreeVersionLocksProUntilItIsTurnedOff() {
        let app = enterDemo()
        openYou(app)
        let row = element(app, "you.demoFreePreview")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the demo offers Preview Free Version")
        let toggle = row.switches.firstMatch
        XCTAssertEqual(toggle.value as? String, "0", "the demo starts with everything unlocked")
        toggle.tap()
        XCTAssertTrue(IOSTest.wait(for: toggle, "value == '1'", timeout: 10), "the switch turned on")
        IOSTest.capture("01-free-preview-on", in: self)

        element(app, "you.statistics").tap()
        let year = app.buttons["Year"].firstMatch
        XCTAssertTrue(year.waitForExistence(timeout: 30), "Statistics shows its ranges")
        year.tap()
        XCTAssertTrue(element(app, "paywall.offer.annual").waitForExistence(timeout: 30), "a locked range opens the paywall in the free preview")
        IOSTest.capture("02-paywall", in: self)
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(IOSTest.wait(for: element(app, "paywall.offer.annual"), "exists == false", timeout: 15), "the paywall closed")

        openYou(app)
        let back = element(app, "you.demoFreePreview")
        XCTAssertTrue(back.waitForExistence(timeout: 20), "the You tab came back to its list")
        back.switches.firstMatch.tap()
        XCTAssertTrue(IOSTest.wait(for: back.switches.firstMatch, "value == '0'", timeout: 10), "the switch turned off")
        element(app, "you.statistics").tap()
        let unlocked = app.buttons["Year"].firstMatch
        XCTAssertTrue(unlocked.waitForExistence(timeout: 30))
        unlocked.tap()
        XCTAssertTrue(IOSTest.wait(for: unlocked, "selected == true", timeout: 10), "with the preview off Year opens")
        XCTAssertFalse(element(app, "paywall.offer.annual").exists, "with the preview off no paywall stands in the way")
        IOSTest.capture("03-unlocked", in: self)
    }

    func testClosingThePlexSignInSheetGivesTheWelcomeScreenBack() {
        let app = IOSTest.launch()
        let demo = element(app, "onboarding.demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 60), "Welcome never showed Try the demo")
        app.buttons["Sign in with Plex"].firstMatch.tap()
        let sheet = app.navigationBars["Sign in to Plex"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 60), "the Plex sign-in sheet never opened")
        XCTAssertFalse(demo.isEnabled, "Try the demo waits while the sign-in runs")
        IOSTest.capture("01-sign-in-sheet", in: self)
        sheet.buttons["Done"].tap()
        XCTAssertTrue(IOSTest.wait(for: sheet, "exists == false", timeout: 15), "the sheet closed")
        XCTAssertTrue(IOSTest.wait(for: demo, "enabled == true", timeout: 5), "Try the demo is ready again at once")
        IOSTest.capture("02-welcome-again", in: self)
        demo.tap()
        XCTAssertTrue(element(app, "demo.intro.start").waitForExistence(timeout: 120), "the demo starts after a closed sign-in")
    }
}
