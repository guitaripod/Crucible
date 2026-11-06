import XCTest

/// Plex Home profiles on iPhone, against the mock server, whose plex.tv has a Home of three: Marcus (the owner), Kids and Sam, whose
/// PIN is 1234. It runs only when `CRUCIBLE_PHONE_MOCK` names the running mock (`tv.sh mock-up` prints it); the built-in demo's own
/// Home is covered by `DemoAccountTypesTests`.
@MainActor
final class ProfilesTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAProfileWithAPINAsksForItAndTheAppComesBackAsThatProfile() throws {
        guard let mock = ProcessInfo.processInfo.environment["CRUCIBLE_PHONE_MOCK"] else {
            throw XCTSkip("Needs the mock server named in CRUCIBLE_PHONE_MOCK")
        }
        _ = URL(string: mock + "/mock/tokens?clear=1").flatMap(Self.fetch)
        let app = IOSTest.launch(extraEnvironment: ["CRUCIBLE_PHONE_MOCK": mock, "CRUCIBLE_PLEXTV": mock])
        openYou(app)
        let row = IOSTest.element(app, "you.switchProfile")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "an account in a Plex Home offers Switch Profile")
        row.tap()
        let sam = IOSTest.element(app, "profiles.Sam")
        XCTAssertTrue(sam.waitForExistence(timeout: 20), "the Home's profiles are listed")
        XCTAssertTrue(IOSTest.element(app, "profiles.Kids").exists)
        IOSTest.capture("01-profiles", in: self)
        sam.tap()
        enterPIN("0000", in: app)
        XCTAssertTrue(app.alerts.staticTexts["That PIN isn\u{2019}t right."].waitForExistence(timeout: 15), "a wrong PIN is refused and asked again")
        IOSTest.capture("02-wrong-pin", in: self)
        enterPIN("1234", in: app)
        XCTAssertTrue(waitForServerToken("mock-server-sam-32c9", mock: mock, timeout: 60), "the app talks to the server as Sam")
        openYou(app)
        let switched = IOSTest.element(app, "you.switchProfile")
        XCTAssertTrue(switched.waitForExistence(timeout: 30))
        let named = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Sam' OR value == 'Sam'")).firstMatch
        XCTAssertTrue(named.waitForExistence(timeout: 15), "You names the profile watching now")
        XCTAssertFalse(IOSTest.element(app, "you.dashboard").exists, "a profile other than the owner's gets no owner tools")
        IOSTest.capture("03-switched-to-sam", in: self)
    }

    private func openYou(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["You"]
        let you = tab.waitForExistence(timeout: 60) ? tab : app.buttons.matching(identifier: "You").firstMatch
        XCTAssertTrue(you.waitForExistence(timeout: 30), "the tab bar never appeared")
        you.tap()
        IOSTest.settle(1)
    }

    private func enterPIN(_ pin: String, in app: XCUIApplication) {
        let field = app.alerts.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "a protected profile asks for its PIN")
        field.tap()
        field.typeText(pin)
        app.alerts.buttons["Switch"].tap()
    }

    private func waitForServerToken(_ token: String, mock: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let url = URL(string: mock + "/mock/tokens"), let data = Self.fetch(url),
               let tokens = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tokens"] as? [String], tokens.contains(token) {
                return true
            }
            IOSTest.settle(1)
        }
        return false
    }

    /// Reads `url` off the main thread, which a synchronous load on it would block.
    private nonisolated static func fetch(_ url: URL) -> Data? {
        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { data, _, _ in
            box.data = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return box.data
    }
}
