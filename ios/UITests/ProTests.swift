import XCTest

/// Drives the Crucible Pro paywall of the iPhone app with the scripted store (`CRUCIBLE_PRO=free`): the demo is the way in that needs
/// no server, and its tour offers the paywall one tap away.
@MainActor
final class ProTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        IOSTest.element(app, identifier)
    }

    private func openPaywall() -> XCUIApplication {
        let app = IOSTest.launch()
        let demo = element(app, "onboarding.demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 60), "Welcome never showed Try the demo")
        demo.tap()
        let start = element(app, "demo.intro.start")
        XCTAssertTrue(start.waitForExistence(timeout: 120), "the demo intro never appeared")
        start.tap()
        let you = app.tabBars.buttons["You"]
        XCTAssertTrue(you.waitForExistence(timeout: 30), "the tab bar never appeared")
        you.tap()
        let tour = element(app, "you.demo")
        XCTAssertTrue(tour.waitForExistence(timeout: 20), "the You tab has no Demo row")
        tour.tap()
        let pro = element(app, "demo.pro")
        XCTAssertTrue(pro.waitForExistence(timeout: 20), "the tour has no Crucible Pro row")
        pro.tap()
        XCTAssertTrue(element(app, "paywall.offer.annual").waitForExistence(timeout: 30), "the paywall never showed its plans")
        IOSTest.settle(1)
        return app
    }

    func testSelectingAnOfferCardChangesTheSelectionTheButtonAndTheDisclosure() {
        let app = openPaywall()
        let lifetime = element(app, "paywall.offer.lifetime")
        let annual = element(app, "paywall.offer.annual")
        let buy = element(app, "paywall.buy")
        let disclosure = element(app, "paywall.disclosure")
        IOSTest.capture("01-lifetime-preselected", in: self)

        XCTAssertTrue(lifetime.isSelected, "the lifetime offer starts selected")
        XCTAssertFalse(annual.isSelected)
        XCTAssertEqual(buy.label, "Unlock for $24.99")
        XCTAssertFalse(disclosure.exists, "a lifetime purchase has no renewal terms")

        annual.tap()
        XCTAssertTrue(IOSTest.wait(for: annual, "isSelected == true", timeout: 5), "tapping the annual card must select it")
        IOSTest.capture("02-annual-selected", in: self)
        XCTAssertFalse(lifetime.isSelected, "selecting annual deselects lifetime")
        XCTAssertEqual(buy.label, "Start 14-day free trial")
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "the annual offer shows its renewal terms")
        XCTAssertTrue(disclosure.label.contains("14-day free trial"), disclosure.label)
        XCTAssertTrue(disclosure.label.contains("renews automatically"), disclosure.label)

        lifetime.tap()
        XCTAssertTrue(IOSTest.wait(for: lifetime, "isSelected == true", timeout: 5), "tapping the lifetime card must select it again")
        XCTAssertFalse(annual.isSelected)
        XCTAssertEqual(buy.label, "Unlock for $24.99")
        XCTAssertTrue(IOSTest.wait(for: disclosure, "exists == false", timeout: 5), "the renewal terms go away with the annual offer")
        IOSTest.capture("03-lifetime-selected-again", in: self)
    }
}
