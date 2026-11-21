import XCTest

/// Reaches the demo library's folders the two quick ways: the folder button beside the library's sort and grid-size buttons, and
/// Shift-Command-O from another tab.
@MainActor
final class LibraryFoldersTests: XCTestCase {
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

    /// The tab called `name`: in the tab bar of an iPhone, among the buttons of the pill an iPad draws.
    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let bar = app.tabBars.buttons[name]
        return bar.waitForExistence(timeout: 5) ? bar : app.buttons.matching(identifier: name).firstMatch
    }

    private func folder(_ app: XCUIApplication) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label CONTAINS %@", "A-F")).firstMatch
    }

    func testTheFolderButtonAndTheShortcutOpenTheLibrarysFolders() {
        let app = enterDemo()
        let library = tab(app, "Library")
        XCTAssertTrue(library.waitForExistence(timeout: 30), "the tab bar has no Library")
        library.tap()
        let button = IOSTest.element(app, "library.folders")
        XCTAssertTrue(button.waitForExistence(timeout: 60), "the library shows no folder button")
        IOSTest.capture("01-library-folder-button", in: self)

        button.tap()
        XCTAssertTrue(folder(app).waitForExistence(timeout: 30), "the folder button did not open the library's folders")
        IOSTest.capture("02-folders", in: self)

        let home = tab(app, "Home")
        XCTAssertTrue(home.waitForExistence(timeout: 30), "the tab bar has no Home")
        home.tap()
        XCTAssertTrue(IOSTest.wait(for: folder(app), "exists == false OR hittable == false", timeout: 30), "Home never replaced the folders")

        app.typeKey("o", modifierFlags: [.command, .shift])
        XCTAssertTrue(IOSTest.wait(for: folder(app), "hittable == true", timeout: 30), "Shift-Command-O did not open the library's folders from Home")
        IOSTest.capture("03-folders-from-shortcut", in: self)
    }
}
