import XCTest

@MainActor
final class PlaceholderTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testSelectPressesTheFocusedButton() {
        let app = TVTest.launch()
        XCTAssertTrue(app.staticTexts["placeholder.title"].waitForExistence(timeout: 15))
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "placeholder.button"))
        TVTest.settle()
        TVTest.capture("01-launch", in: self)

        TVTest.remote.press(.right)
        TVTest.remote.press(.select)
        TVTest.settle()

        XCTAssertTrue(app.buttons["placeholder.button"].label.contains("Selected"))
        TVTest.capture("02-after-select", in: self)
    }
}
