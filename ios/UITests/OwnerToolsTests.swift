import XCTest

/// The server owner's tools on the iPhone, against the built-in demo, whose account owns its server: Edit Details and Fix Match from a
/// title's menu, stopping someone's stream and the Server Dashboard from Server Activity, and removing a play from Watch History.
@MainActor
final class OwnerToolsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func enterDemo() -> XCUIApplication {
        let app = IOSTest.launch()
        let demo = IOSTest.element(app, "onboarding.demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 120), "Welcome never showed Try the demo")
        demo.tap()
        let start = IOSTest.element(app, "demo.intro.start")
        XCTAssertTrue(start.waitForExistence(timeout: 180), "the demo intro never appeared")
        start.tap()
        XCTAssertTrue(IOSTest.wait(for: start, "exists == false OR hittable == false", timeout: 30), "the intro never closed")
        IOSTest.settle(2)
        return app
    }

    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let bar = app.tabBars.buttons[name]
        return bar.waitForExistence(timeout: 5) ? bar : app.buttons.matching(identifier: name).firstMatch
    }

    private func card(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    private func openTitle(_ app: XCUIApplication, _ title: String) {
        let search = tab(app, "Search")
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        let field = app.searchFields.firstMatch
        for _ in 0..<3 where !field.exists {
            search.tap()
            _ = field.waitForExistence(timeout: 10)
        }
        field.tap()
        field.typeText(title)
        let result = card(app, title)
        XCTAssertTrue(result.waitForExistence(timeout: 60), "search found no \(title)")
        result.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Rate' OR label BEGINSWITH 'Your rating'")).firstMatch.waitForExistence(timeout: 30), "\(title) never opened")
    }

    /// Opens the title's More menu and its Manage submenu, then picks `action`.
    private func manage(_ app: XCUIApplication, _ action: String) {
        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 20), "the detail has no More button")
        more.tap()
        let manage = app.buttons["Manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 20), "the owner's title menu has no Manage")
        manage.tap()
        let item = app.buttons[action]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "Manage offers no \(action)")
        IOSTest.capture("manage-menu", in: self)
        item.tap()
    }

    private func openYouRow(_ app: XCUIApplication, _ identifier: String) {
        tab(app, "You").tap()
        let row = IOSTest.element(app, identifier)
        for _ in 0..<6 where !row.isHittable {
            app.collectionViews.firstMatch.swipeUp()
            IOSTest.settle(0.4)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 20), "You has no \(identifier) row")
        row.tap()
    }

    func testEditDetailsRenamesTheTitle() {
        let app = enterDemo()
        openTitle(app, "Low Tide")
        manage(app, "Edit Details…")
        let field = app.textFields["Title"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Edit Details has no Title field")
        field.tap()
        field.buttons.firstMatch.tap()
        field.typeText("Low Tide Revisited")
        IOSTest.capture("01-edit-details", in: self)
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Play Low Tide Revisited"].waitForExistence(timeout: 20), "the detail never showed the new title")
        IOSTest.capture("02-renamed", in: self)
    }

    func testFixMatchListsCandidatesAndMatchesOne() {
        let app = enterDemo()
        openTitle(app, "Low Tide")
        manage(app, "Fix Match…")
        let candidate = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'fixMatch.result.'"))
        XCTAssertTrue(candidate.firstMatch.waitForExistence(timeout: 20), "Fix Match listed no candidates")
        XCTAssertEqual(candidate.count, 3)
        IOSTest.capture("01-fix-match", in: self)
        candidate.element(boundBy: 1).tap()
        let confirm = app.alerts.buttons["Match"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "picking a candidate asked for no confirmation")
        confirm.tap()
        XCTAssertTrue(IOSTest.wait(for: app.navigationBars["Fix Match"], "exists == false", timeout: 20), "Fix Match stayed open after matching")
    }

    func testStoppingAStreamEndsItAndTheDashboardOffersTheUpdate() {
        let app = enterDemo()
        openYouRow(app, "you.activity")
        let maren = card(app, "Maren")
        XCTAssertTrue(maren.waitForExistence(timeout: 30), "Server Activity shows no stream of Maren's")
        IOSTest.capture("01-activity", in: self)
        maren.press(forDuration: 1.2)
        let stop = app.buttons["Stop Stream…"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the owner's stream menu has no Stop Stream")
        stop.tap()
        let reason = app.buttons["Maintenance, back soon."]
        XCTAssertTrue(reason.waitForExistence(timeout: 10), "Stop Stream offers no reasons")
        reason.tap()
        XCTAssertTrue(IOSTest.wait(for: maren, "exists == false", timeout: 30), "the stopped stream stayed in Server Activity")
        let dashboard = app.navigationBars.buttons["Server Dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 10), "Server Activity has no Server Dashboard button for the owner")
        dashboard.tap()
        let update = app.staticTexts["Update Available"]
        XCTAssertTrue(update.waitForExistence(timeout: 20), "the dashboard offers no server update")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'CPU '")).firstMatch.waitForExistence(timeout: 10), "the dashboard shows no load")
        IOSTest.capture("02-dashboard", in: self)
        update.tap()
        let notes = app.alerts.firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 10), "the update showed no release notes")
        XCTAssertTrue(notes.buttons["Install Now"].exists)
        notes.buttons["Later"].tap()
    }

    func testRemovingAPlayTakesItOffWatchHistory() {
        let app = enterDemo()
        openYouRow(app, "you.history")
        let first = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'history.row.'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30), "Watch History listed nothing")
        let row = IOSTest.element(app, first.identifier)
        IOSTest.capture("01-history", in: self)
        first.swipeLeft()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "the owner's swipe offers no Remove")
        remove.tap()
        XCTAssertTrue(IOSTest.wait(for: row, "exists == false", timeout: 20), "the removed play stayed in Watch History")
        IOSTest.capture("02-removed", in: self)
    }
}
