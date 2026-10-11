import XCTest

/// Drives sign-in against the mock's plex.tv surface (`CRUCIBLE_PLEXTV`), from a fresh install
/// state (`CRUCIBLE_FRESH=1`), and captures every screen. The mock is reconfigured per test through
/// `/mock/plextv-config`.
@MainActor
final class OnboardingTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private var mockURL: String {
        ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"] ?? ""
    }

    private func configureMock(polls: Int = 3, expires: Int = 900, servers: String = "default") {
        guard let url = URL(string: "\(mockURL)/mock/plextv-config?pin_polls=\(polls)&pin_expires=\(expires)&servers=\(servers)") else {
            XCTFail("CRUCIBLE_MOCK is not set: start the mock with tv.sh mock-up")
            return
        }
        let done = expectation(description: "mock configured")
        URLSession.shared.dataTask(with: url) { _, response, _ in
            if (response as? HTTPURLResponse)?.statusCode != 200 { XCTFail("mock refused the plex.tv configuration") }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
    }

    private func launch(style: String? = nil) -> XCUIApplication {
        var environment = ["CRUCIBLE_MOCK": "", "CRUCIBLE_PLEXTV": mockURL, "CRUCIBLE_FRESH": "1"]
        if let style { environment["CRUCIBLE_STYLE"] = style }
        return TVTest.launch(extraEnvironment: environment)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func codeValue(_ app: XCUIApplication, timeout: TimeInterval = 20) -> String? {
        let code = element(app, "onboarding.code")
        guard code.waitForExistence(timeout: timeout) else { return nil }
        let predicate = NSPredicate(format: "value MATCHES %@", "[A-Z] [A-Z] [A-Z] [A-Z]")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: code)
        guard XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed else { return nil }
        return code.value as? String
    }

    /// Moves from the keyboard's letter row to its go key and presses it.
    private func pressGo() {
        for _ in 0..<3 { TVTest.remote.press(.down) }
        TVTest.remote.press(.select)
    }

    private func signIn(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["onboarding.signIn"].waitForExistence(timeout: 20))
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "onboarding.signIn"))
        TVTest.remote.press(.select)
    }

    private func waitForMainApp(_ app: XCUIApplication, timeout: TimeInterval = 60) {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: timeout), "the signed-in app never appeared")
    }

    func testWelcomeAndTheCodeScreen() {
        configureMock(polls: 1000)
        let app = launch()
        XCTAssertTrue(app.buttons["onboarding.signIn"].waitForExistence(timeout: 20))
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "onboarding.signIn"))
        TVTest.settle()
        TVTest.capture("01-welcome", in: self)

        TVTest.remote.press(.select)
        let code = codeValue(app)
        XCTAssertNotNil(code, "the four character code never appeared")
        XCTAssertTrue(element(app, "onboarding.qr").waitForExistence(timeout: 10))
        TVTest.settle(2)
        TVTest.capture("02-code-waiting", in: self)

        TVTest.remote.press(.menu)
        XCTAssertTrue(app.buttons["onboarding.signIn"].waitForExistence(timeout: 10), "Back on the code screen must return to Welcome")
        TVTest.settle()
        TVTest.capture("03-back-on-welcome", in: self)
    }

    func testTheCodeCompletesByItselfAndContinuesToHome() {
        configureMock(polls: 2)
        let app = launch()
        signIn(app)
        XCTAssertNotNil(codeValue(app))
        TVTest.settle(1)
        TVTest.capture("04-code-before-approval", in: self)
        waitForMainApp(app)
        TVTest.settle(2)
        TVTest.capture("05-home-after-sign-in", in: self)
    }

    func testAnExpiredCodeOffersANewOneWithFocus() {
        configureMock(polls: 1000, expires: 4)
        let app = launch()
        signIn(app)
        let first = codeValue(app)
        XCTAssertNotNil(first)
        let newCode = app.buttons["onboarding.newCode"]
        XCTAssertTrue(newCode.waitForExistence(timeout: 30), "an expired code must offer Get a New Code")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "onboarding.newCode"), "focus must move to Get a New Code")
        TVTest.settle()
        TVTest.capture("06-code-expired", in: self)

        configureMock(polls: 1000, expires: 600)
        TVTest.remote.press(.select)
        let second = codeValue(app)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second, "a new session must show a new code")
        XCTAssertFalse(newCode.exists)
        TVTest.settle(2)
        TVTest.capture("07-fresh-code", in: self)
    }

    func testSeveralServersAreListedWithTheirRoutes() {
        configureMock(polls: 1, servers: "several")
        let app = launch()
        signIn(app)
        let list = app.collectionViews["onboarding.servers"]
        XCTAssertTrue(list.waitForExistence(timeout: 30))
        XCTAssertTrue(list.cells.element(boundBy: 0).waitForExistence(timeout: 10))
        TVTest.settle(9)
        TVTest.capture("08-servers", in: self)

        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        TVTest.settle()
        TVTest.capture("09-unreachable-server-focused", in: self)

        TVTest.remote.press(.up)
        TVTest.remote.press(.up)
        TVTest.settle()
        TVTest.remote.press(.select)
        waitForMainApp(app)
    }

    func testOneReachableServerContinuesAutomatically() {
        configureMock(polls: 1, servers: "multiple")
        let app = launch()
        signIn(app)
        waitForMainApp(app)
    }

    func testAnUnreachableOnlyServerOffersAnAddress() {
        configureMock(polls: 1, servers: "unreachable")
        let app = launch()
        signIn(app)
        XCTAssertTrue(app.staticTexts["Couldn't Reach Marcus-PC"].waitForExistence(timeout: 40))
        TVTest.settle(2)
        TVTest.capture("10-server-unreachable", in: self)

        TVTest.remote.press(.select)
        let field = app.textFields["onboarding.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        TVTest.settle()
        TVTest.capture("11-address", in: self)

        let host = URL(string: mockURL).map { "\($0.host ?? "127.0.0.1"):\($0.port ?? 32400)" } ?? "127.0.0.1:32400"
        TVTest.remote.press(.select)
        TVTest.settle(2)
        TVTest.capture("12-keyboard", in: self)
        app.typeText(host)
        TVTest.settle(1)
        TVTest.capture("12b-keyboard-typed", in: self)
        pressGo()
        waitForMainApp(app)
    }

    func testAnAddressNobodyAnswersShowsAnError() {
        configureMock(polls: 1, servers: "unreachable")
        let app = launch()
        signIn(app)
        XCTAssertTrue(app.staticTexts["Couldn't Reach Marcus-PC"].waitForExistence(timeout: 40))
        TVTest.remote.press(.select)
        XCTAssertTrue(app.textFields["onboarding.address"].waitForExistence(timeout: 10))
        TVTest.remote.press(.select)
        TVTest.settle(2)
        app.typeText("127.0.0.1:1")
        pressGo()
        let error = element(app, "onboarding.error")
        XCTAssertTrue(error.waitForExistence(timeout: 30))
        TVTest.settle()
        TVTest.capture("14-address-error", in: self)
    }

    func testAnAccountWithoutServersSaysSo() {
        configureMock(polls: 1, servers: "none")
        let app = launch()
        signIn(app)
        XCTAssertTrue(app.staticTexts["No Plex Server Found"].waitForExistence(timeout: 30))
        TVTest.settle(2)
        TVTest.capture("15-no-servers", in: self)

        TVTest.remote.press(.menu)
        XCTAssertTrue(app.buttons["onboarding.signIn"].waitForExistence(timeout: 10), "Back from the server list returns to Welcome, never to a dead code")
    }

    func testLightWelcomeCodeAndServers() {
        configureMock(polls: 1000, servers: "several")
        let app = launch(style: "light")
        XCTAssertTrue(app.buttons["onboarding.signIn"].waitForExistence(timeout: 20))
        TVTest.settle()
        TVTest.capture("16-light-welcome", in: self)
        TVTest.remote.press(.select)
        XCTAssertNotNil(codeValue(app))
        TVTest.settle(2)
        TVTest.capture("17-light-code", in: self)
        TVTest.remote.press(.menu)
        configureMock(polls: 1, servers: "several")
        XCTAssertTrue(app.buttons["onboarding.signIn"].waitForExistence(timeout: 10))
        TVTest.remote.press(.select)
        XCTAssertTrue(app.collectionViews["onboarding.servers"].waitForExistence(timeout: 30))
        TVTest.settle(9)
        TVTest.capture("18-light-servers", in: self)
        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        TVTest.settle()
        TVTest.capture("19-light-unreachable-focused", in: self)
    }

    /// With a saved session the app writes the Top Shelf snapshot; focusing the app on the Apple TV
    /// Home screen shows it. Needs the mock (CRUCIBLE_MOCK) and the extension to launch.
    func testTopShelfShowsContinueWatchingOnTheHomeScreen() {
        configureMock()
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_FRESH": "1", "CRUCIBLE_MOCK": mockURL])
        waitForMainApp(app)
        TVTest.settle(6)
        TVTest.remote.press(.home)
        TVTest.settle(3)
        for _ in 0..<3 { TVTest.remote.press(.left) }
        TVTest.remote.press(.right)
        TVTest.settle(10)
        TVTest.capture("20-top-shelf", in: self)
    }

    /// A saved server that does not answer and that plex.tv knows no alternative to (the launch
    /// pipeline would otherwise heal onto one): Switch Server lists the account's servers once
    /// plex.tv offers one, connects to it and relaunches onto it.
    func testSwitchServerFromTheFailureScreenRelaunchesOnTheNewServer() {
        configureMock(servers: "none")
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_MOCK": "http://127.0.0.1:1", "CRUCIBLE_PLEXTV": mockURL])
        XCTAssertTrue(app.buttons["launch.switchServer"].waitForExistence(timeout: 150))
        configureMock(servers: "default")
        TVTest.remote.press(.right)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "launch.switchServer"))
        TVTest.remote.press(.select)
        waitForMainApp(app, timeout: 90)
    }
}
