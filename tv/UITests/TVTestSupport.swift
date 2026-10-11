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

    /// Returns the mock Plex server to its defaults and then applies `settings` (`MOCK_*` names such
    /// as `MOCK_NO_HISTORY` or `MOCK_LIBRARY_PAD`, through the mock's `/mock/env`), so a test states
    /// the server it needs instead of relying on how the mock was started. A flag or number is
    /// switched off by "0".
    static func configureMock(_ settings: [String: String] = [:]) {
        guard let base = ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"],
              var components = URLComponents(string: base + "/mock/env") else { return }
        components.queryItems = [URLQueryItem(name: "reset", value: "1")] + settings.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return }
        fetch(url)
    }

    /// Loads `url` with a data task and waits for the answer for at most 15 seconds, returning nil on failure. Loading an http URL synchronously through the Foundation convenience initialisers is reported by the system as a runtime issue when it runs on the main thread, and `tv.sh uitest` refuses to start while a test uses them.
    @discardableResult
    nonisolated static func fetch(_ url: URL) -> Data? {
        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { data, _, _ in
            box.data = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        return box.data
    }

    /// Launches the app with `CRUCIBLE_UITEST=1` and forwards every `CRUCIBLE_*` variable that `tv.sh uitest` handed over as a `TEST_RUNNER_*` variable (`CRUCIBLE_MOCK`, `CRUCIBLE_PLEXTV`, `CRUCIBLE_STYLE`, ...). Every launch first resets the mock to its defaults and then applies `mock`, so tests never inherit what an earlier test switched on; a relaunch inside a test passes `mock` again.
    static func launch(mock settings: [String: String] = [:], extraEnvironment: [String: String] = [:], arguments: [String] = []) -> XCUIApplication {
        configureMock(settings)
        let app = XCUIApplication()
        app.launchArguments += arguments
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

    /// Waits until `element` has focus; for buttons that have a label but no accessibility identifier, such as the ones of a `TVStateView`.
    @discardableResult
    static func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
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
