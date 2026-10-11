import XCTest
import UIKit

@MainActor
final class TourTests: XCTestCase {
    private static let requiredTabs = ["Home", "Movies", "TV Shows", "Documentaries", "Search", "You"]
    private static let deadServer = "http://127.0.0.1:1"

    override func setUp() {
        continueAfterFailure = false
    }

    func testEveryTabShowsItsScreen() {
        let app = TVTest.launch()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30))
        TVTest.settle()

        let titles = tabBar.buttons.allElementsBoundByIndex.map(\.label)
        for required in Self.requiredTabs {
            XCTAssertTrue(titles.contains(required), "tab \(required) missing from \(titles)")
        }
        XCTAssertEqual(titles.first, "Home")
        XCTAssertEqual(titles.last, "You")

        for (index, title) in titles.enumerated() {
            if index > 0 {
                TVTest.remote.press(.right)
            }
            TVTest.remote.press(.select)
            TVTest.settle()
            XCTAssertTrue(tabBar.buttons[title].hasFocus, "focus should be on \(title)")
            XCTAssertTrue(app.staticTexts["placeholder.title"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["placeholder.title"].label, title)
            TVTest.capture(String(format: "%02d-%@", index + 1, Self.slug(title)), in: self)
        }
    }

    func testUnreachableServerOffersTryAgainAndSwitchServer() {
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_MOCK": Self.deadServer])
        let retry = app.buttons["launch.retry"]
        let switchServer = app.buttons["launch.switchServer"]
        XCTAssertTrue(retry.waitForExistence(timeout: 90))
        XCTAssertTrue(switchServer.exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "launch.retry"))
        TVTest.settle()
        TVTest.capture("01-failure-try-again-focused", in: self)

        TVTest.remote.press(.right)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "launch.switchServer"))
        TVTest.settle()
        TVTest.capture("02-failure-switch-server-focused", in: self)

        TVTest.remote.press(.select)
        XCTAssertTrue(app.collectionViews["onboarding.servers"].waitForExistence(timeout: 45), "Switch Server must present the server list for the saved account")
        TVTest.settle()
        TVTest.capture("03-switch-server-presented", in: self)

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "launch.switchServer"))

        TVTest.remote.press(.left)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "launch.retry"))
        TVTest.remote.press(.select)
        TVTest.settle(0.3)
        TVTest.capture("04-retrying", in: self)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "launch.retry", timeout: 90))
    }

    func testDeepLinksSelectHomeAndOpenDetailOrPlay() {
        let app = TVTest.launch()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30))
        TVTest.settle()
        TVTest.remote.press(.right)
        TVTest.remote.press(.select)
        TVTest.settle()
        XCTAssertTrue(tabBar.buttons["Movies"].hasFocus)
        XCTAssertEqual(app.staticTexts["placeholder.title"].label, "Movies")

        openFromOutside("crucible://item/4009?type=episode")
        XCTAssertTrue(app.staticTexts["placeholder.title"].waitForExistence(timeout: 10))
        TVTest.settle()
        XCTAssertEqual(app.staticTexts["placeholder.title"].label, "Detail 4009")
        TVTest.capture("01-item-link-opened-detail-on-home", in: self)

        openFromOutside("crucible://item/1002")
        XCTAssertTrue(app.staticTexts["placeholder.title"].waitForExistence(timeout: 10))
        TVTest.settle()
        XCTAssertEqual(app.staticTexts["placeholder.title"].label, "Detail 1002")

        openFromOutside("crucible://play/1002")
        XCTAssertTrue(app.alerts["Deep Field"].waitForExistence(timeout: 10))
        TVTest.capture("02-play-link-reached-the-player-seam", in: self)
    }

    func testLinkThatLaunchesTheAppWaitsForTheMainUI() {
        let app = TVTest.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        app.terminate()

        openFromOutside("crucible://item/4009?type=episode")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["placeholder.title"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["placeholder.title"].label, "Detail 4009")
        TVTest.settle()
        TVTest.capture("01-launch-link-opened-detail", in: self)
    }

    /// Hands a URL to the system the way Top Shelf does. The first time the system asks "Open in
    /// Crucible?" and the prompt is confirmed with Select; later links go straight through.
    private func openFromOutside(_ link: String) {
        let url = URL(string: link)!
        Task { _ = await UIApplication.shared.open(url) }
        let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if prompt.waitForExistence(timeout: 3) {
            TVTest.remote.press(.select)
        }
        TVTest.settle(1.0)
    }

    private static func slug(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}
