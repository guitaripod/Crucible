import XCTest

@MainActor
struct Remote {
    private let remote = XCUIRemote.shared

    func press(_ button: XCUIRemote.Button) {
        remote.press(button)
    }

    func longPress(_ button: XCUIRemote.Button, duration: TimeInterval = 1.0) {
        remote.press(button, forDuration: duration)
    }
}

@MainActor
enum TVTest {
    static let remote = Remote()

    /// Launches the app with `CRUCIBLE_UITEST=1` and forwards every `CRUCIBLE_*` variable that `tv.sh uitest` handed over as a `TEST_RUNNER_*` variable (`CRUCIBLE_MOCK`, `CRUCIBLE_PLEXTV`, `CRUCIBLE_STYLE`, ...).
    static func launch(extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CRUCIBLE_UITEST"] = "1"
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("CRUCIBLE_") {
            app.launchEnvironment[key] = value
        }
        app.launchEnvironment.merge(extraEnvironment) { _, new in new }
        app.launch()
        return app
    }

    /// Attaches a full-screen screenshot named `name` that `tv.sh uitest` exports to `tv/out/ui/<test>/<name>.png`.
    static func capture(_ name: String, in test: XCTestCase) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    static func settle(_ seconds: TimeInterval = 1.0) {
        let pause = XCTestExpectation(description: "settle \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { pause.fulfill() }
        XCTWaiter().wait(for: [pause], timeout: seconds + 5)
    }

    /// Waits until the element with the accessibility `identifier` has focus; returns whether it did within `timeout`.
    @discardableResult
    static func waitForFocus(
        on app: XCUIApplication,
        identifier: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        let predicate = NSPredicate(format: "hasFocus == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
