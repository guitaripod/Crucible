import XCTest

/// The server owner's tools on Apple TV, against the mock, whose plex.tv says the account owns the server: Stop Stream in Server
/// Activity's long-press menu, and Manage in a title's long-press menu on Home.
@MainActor
final class OwnerToolsTests: TVTestCase {
    private var mockURL: String { ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"] ?? "" }

    /// Presses Down until the open menu's item labelled `label` has focus; returns whether it got there.
    private func focusMenuItem(_ app: XCUIApplication, _ label: String, limit: Int = 12) -> Bool {
        for _ in 0..<limit {
            if focusIsOn(app, label) { return true }
            TVTest.remote.press(.down)
            TVTest.settle(0.5)
        }
        return focusIsOn(app, label)
    }

    /// A menu item takes focus as an unlabelled cell whose child carries the title.
    private func focusIsOn(_ app: XCUIApplication, _ label: String) -> Bool {
        let focused = AppNavigation.focusedElement(app)
        return focused.label == label || focused.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).count > 0
    }

    func testStoppingAStreamTakesItOffServerActivity() {
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_PLEXTV": mockURL])
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.activity")
        let stream = AppNavigation.element(app, "grid.1001")
        XCTAssertTrue(stream.waitForExistence(timeout: 30), "Server Activity shows no stream of Halcyon")
        XCTAssertTrue(AppNavigation.move(app, .left, untilFocusHasPrefix: "grid.1001", limit: 3), "focus never reached the Halcyon stream")
        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1.0)
        XCTAssertTrue(app.descendants(matching: .any)["Stop Stream…"].waitForExistence(timeout: 5), "the owner's stream menu has no Stop Stream")
        XCTAssertTrue(focusMenuItem(app, "Stop Stream…"), "focus never reached Stop Stream")
        TVTest.capture("01-stop-stream", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        XCTAssertTrue(focusMenuItem(app, "Maintenance, back soon."), "Stop Stream offers no reasons")
        TVTest.capture("02-reasons", in: self)
        TVTest.remote.press(.select)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stream)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 20), .completed, "the stopped stream stayed in Server Activity")
        XCTAssertTrue(AppNavigation.element(app, "grid.4012").exists, "the other stream went too")
    }

    func testATitlesMenuOffersManageAndRefreshesItsMetadata() {
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_PLEXTV": mockURL])
        XCTAssertTrue(AppNavigation.move(app, .down, untilFocusHasPrefix: "home.card.continueWatching.", limit: 6), "focus never reached Continue Watching")
        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1.0)
        XCTAssertTrue(app.descendants(matching: .any)["Manage"].waitForExistence(timeout: 5), "the owner's title menu has no Manage")
        XCTAssertTrue(focusMenuItem(app, "Manage"), "focus never reached Manage")
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        XCTAssertTrue(focusMenuItem(app, "Refresh Metadata"), "Manage offers no Refresh Metadata")
        TVTest.capture("03-manage", in: self)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.alerts["Sent to Your Server"].waitForExistence(timeout: 15), "refreshing gave no word that the server took it")
        TVTest.capture("04-sent", in: self)
    }
}
