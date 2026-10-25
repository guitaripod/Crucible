import XCTest

/// Shared launch, waiting and capture helpers for the iPhone UI tests.
@MainActor
enum IOSTest {
    /// Launches the app as a new install with the scripted free store: `CRUCIBLE_UITEST=1`, `CRUCIBLE_FRESH=1` and `CRUCIBLE_PRO=free`, plus every `CRUCIBLE_*` variable `ios.sh test` handed over as a `TEST_RUNNER_*` variable. `extraEnvironment` wins over all of them.
    static func launch(fresh: Bool = true, extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CRUCIBLE_UITEST"] = "1"
        app.launchEnvironment["CRUCIBLE_PRO"] = "free"
        if fresh { app.launchEnvironment["CRUCIBLE_FRESH"] = "1" }
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("CRUCIBLE_") {
            app.launchEnvironment[key] = value
        }
        app.launchEnvironment.merge(extraEnvironment) { _, new in new }
        app.launch()
        return app
    }

    static func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Attaches a full-screen screenshot named `name` that `ios.sh test` exports to `ios/out/ui/<test>/<name>.png`.
    static func capture(_ name: String, in test: XCTestCase) {
        let attachment = XCTAttachment(image: upright(XCUIScreen.main.screenshot().image))
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    /// The simulator's screenshot is always in the panel's portrait orientation; a rotated iPad is turned back so the capture reads the way
    /// the screen did.
    private static func upright(_ image: UIImage) -> UIImage {
        let orientation: UIImage.Orientation
        switch XCUIDevice.shared.orientation {
        case .landscapeLeft: orientation = .left
        case .landscapeRight: orientation = .right
        case .portraitUpsideDown: orientation = .down
        default: return image
        }
        guard let cgImage = image.cgImage else { return image }
        let turned = UIImage(cgImage: cgImage, scale: image.scale, orientation: orientation)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: turned.size, format: format).image { _ in turned.draw(at: .zero) }
    }

    static func settle(_ seconds: TimeInterval = 1.0) {
        let pause = XCTestExpectation(description: "settle \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { pause.fulfill() }
        XCTWaiter().wait(for: [pause], timeout: seconds + 5)
    }

    /// Waits until `predicate` holds for `element`; returns whether it did within `timeout`.
    @discardableResult
    static func wait(for element: XCUIElement, _ predicate: String, timeout: TimeInterval = 20) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
