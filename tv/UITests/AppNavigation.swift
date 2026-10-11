import UIKit
import XCTest

/// Navigation helpers for the app-level tests that cross feature boundaries: the tab bar, the focus
/// engine and links handed to the app from outside.
@MainActor
enum AppNavigation {
    static let homeCardPrefix = "home.card."

    static func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    static func firstElement(_ app: XCUIApplication, prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    static func focusedElement(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    static func focusedIdentifier(_ app: XCUIApplication) -> String {
        focusedElement(app).identifier
    }

    /// Launches the signed-in app and waits until Home shows its first card.
    static func launchHome(mock: [String: String] = [:], extraEnvironment: [String: String] = [:], arguments: [String] = []) -> XCUIApplication {
        let app = TVTest.launch(mock: mock, extraEnvironment: extraEnvironment, arguments: arguments)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60), "the main UI never appeared")
        XCTAssertTrue(firstElement(app, prefix: homeCardPrefix).waitForExistence(timeout: 60), "Home never showed a card")
        TVTest.settle(1.5)
        return app
    }

    /// Presses `button` until the focused element's identifier starts with `prefix`; returns whether it got there.
    @discardableResult
    static func move(_ app: XCUIApplication, _ button: XCUIRemote.Button, untilFocusHasPrefix prefix: String, limit: Int = 14) -> Bool {
        for _ in 0..<limit {
            if focusedIdentifier(app).hasPrefix(prefix) { return true }
            TVTest.remote.press(button)
            TVTest.settle(0.5)
        }
        return focusedIdentifier(app).hasPrefix(prefix)
    }

    /// Brings focus back to the tab bar from anywhere in a tab's root screen.
    static func focusTabBar(_ app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        for _ in 0..<3 {
            if tabBar.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists { return }
            TVTest.remote.press(.menu)
            TVTest.settle(1.0)
        }
    }

    /// Moves focus along the tab bar to the tab called `title` and selects it.
    static func selectTab(_ title: String, in app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        focusTabBar(app)
        let titles = tabBar.buttons.allElementsBoundByIndex.map(\.label)
        guard let target = titles.firstIndex(of: title) else {
            XCTFail("tab \(title) missing from \(titles)")
            return
        }
        guard let current = titles.firstIndex(where: { tabBar.buttons[$0].hasFocus }) else {
            XCTFail("focus never reached the tab bar")
            return
        }
        let direction: XCUIRemote.Button = target > current ? .right : .left
        for _ in 0..<abs(target - current) {
            TVTest.remote.press(direction)
            TVTest.settle(0.4)
        }
        XCTAssertTrue(tabBar.buttons[title].hasFocus, "focus should be on \(title)")
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
    }

    private static var promptSeen = false

    private static func openPrompt() -> XCUIElement? {
        for bundle in ["com.apple.PineBoard", "com.apple.springboard"] {
            let system = XCUIApplication(bundleIdentifier: bundle)
            for query in [system.buttons, system.descendants(matching: .button)] {
                let button = query["Open"]
                if button.exists { return button }
            }
        }
        return nil
    }

    /// Hands a `crucible://` URL to the system the way Top Shelf does. The system asks "Open in
    /// Crucible?", which can take several seconds to appear and is confirmed with Select.
    static func openFromOutside(_ link: String, in test: XCTestCase? = nil) {
        let url = URL(string: link)!
        Task { _ = await UIApplication.shared.open(url) }
        let polls = promptSeen ? 6 : 24
        for _ in 0..<polls {
            if openPrompt() != nil {
                TVTest.remote.press(.select)
                promptSeen = true
                break
            }
            TVTest.settle(0.5)
        }
        if !promptSeen, let test {
            let attachment = XCTAttachment(string: XCUIApplication(bundleIdentifier: "com.apple.PineBoard").debugDescription)
            attachment.name = "pineboard"
            attachment.lifetime = .keepAlways
            test.add(attachment)
        }
        TVTest.settle(0.8)
    }

    /// Sets a flag of the mock server (`latency_ms` and friends) through `/mock/flags`.
    static func setMockFlags(_ query: String) {
        guard let base = ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"],
              let url = URL(string: "\(base)/mock/flags?\(query)") else { return }
        TVTest.fetch(url)
    }

    /// Writes the item's resume position to the mock, so a play link starts inside the 150 s clip instead of at the stored 52 minutes, which is past its end and closes the player at once.
    static func setMockProgress(_ ratingKey: String, seconds: Int) {
        let path = "/:/timeline?ratingKey=\(ratingKey)&key=/library/metadata/\(ratingKey)&state=stopped&time=\(seconds * 1000)&duration=2700000"
        guard let base = ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"], let url = URL(string: base + path) else { return }
        TVTest.fetch(url)
    }

    static func detailPrimary(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["detail.action.primary"]
    }

    /// Waits for a detail screen, focus on its primary action.
    static func expectDetail(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(detailPrimary(app).waitForExistence(timeout: 30), "the detail screen never appeared", file: file, line: line)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.primary", timeout: 10), "focus should rest on the primary action, not on \(focusedIdentifier(app))", file: file, line: line)
        TVTest.settle(1.0)
    }

    /// Pops the detail on top of Home with Menu and expects Home's own cards underneath, which is how a test knows a link opened on Home. A link leaves focus on the tab bar, where Menu would leave the app, so focus first enters the screen.
    static func expectHomeUnderDetail(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        if app.tabBars.firstMatch.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists {
            TVTest.remote.press(.down)
            TVTest.settle(1.0)
        }
        TVTest.remote.press(.menu)
        XCTAssertTrue(firstElement(app, prefix: homeCardPrefix).waitForExistence(timeout: 15), "Menu from the linked Detail must land on Home", file: file, line: line)
        TVTest.settle(1.0)
    }

    static func isPlayerUp(_ app: XCUIApplication) -> Bool {
        app.otherElements["player.preroll"].exists || app.otherElements["player.view"].exists
    }

    /// Presses Menu until the player (pre-roll or playback) is gone.
    static func leavePlayer(_ app: XCUIApplication, limit: Int = 8) {
        for _ in 0..<limit where isPlayerUp(app) {
            TVTest.remote.press(.menu)
            TVTest.settle(2.0)
        }
        XCTAssertFalse(isPlayerUp(app), "Menu never left the player")
    }
}
