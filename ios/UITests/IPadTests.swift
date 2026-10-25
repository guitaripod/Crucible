import XCTest

/// Drives the built-in demo on an iPad: every orientation, the keyboard shortcuts that switch tabs, the sidebar's libraries and the
/// back and refresh commands. Skips itself on any other device, so `ios.sh test` on the iPhone simulator passes over it.
@MainActor
final class IPadTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        IOSTest.element(app, identifier)
    }

    private func homeTitle(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars["Home"]
    }

    private func backButton(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons["BackButton"].firstMatch
    }

    private func enterDemo() -> XCUIApplication {
        let app = IOSTest.launch()
        let demo = element(app, "onboarding.demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 120), "Welcome never showed Try the demo")
        demo.tap()
        let start = element(app, "demo.intro.start")
        XCTAssertTrue(start.waitForExistence(timeout: 180), "the demo intro never appeared")
        start.tap()
        XCTAssertTrue(IOSTest.wait(for: start, "exists == false OR hittable == false", timeout: 30), "the intro never closed")
        XCTAssertTrue(IOSTest.wait(for: homeTitle(app), "exists == true", timeout: 120), "Home never appeared")
        IOSTest.settle(2)
        return app
    }

    private func assertRunning(_ app: XCUIApplication, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "the app is no longer running after \(step)", file: file, line: line)
    }

    private func rotate(to orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        IOSTest.settle(2)
    }

    private func press(_ app: XCUIApplication, _ key: String, _ flags: XCUIElement.KeyModifierFlags = .command, _ step: String) {
        app.typeKey(key, modifierFlags: flags)
        IOSTest.settle(2)
        assertRunning(app, step)
    }

    /// The sidebar's entry for the library called `titles`' first match: a button, a cell or a text with that name.
    private func libraryEntry(_ app: XCUIApplication, _ titles: [String]) -> XCUIElement? {
        for title in titles {
            for candidate in [app.buttons[title], app.cells[title], app.staticTexts[title]] where candidate.exists {
                return candidate
            }
        }
        return nil
    }

    private func revealSidebar(_ app: XCUIApplication) {
        guard libraryEntry(app, ["Movies"]) == nil else { return }
        for name in ["Show Sidebar", "Sidebar", "Hide Sidebar"] {
            let toggle = app.buttons[name]
            if toggle.exists {
                toggle.tap()
                IOSTest.settle(1.5)
                return
            }
        }
    }

    private func hasKeyboardFocus(_ field: XCUIElement) -> Bool {
        (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    func testRotatesThroughEveryOrientation() {
        let app = enterDemo()
        let orientations: [(String, UIDeviceOrientation)] = [
            ("01-portrait", .portrait), ("02-landscape-left", .landscapeLeft),
            ("03-portrait-upside-down", .portraitUpsideDown), ("04-landscape-right", .landscapeRight),
        ]
        for (name, orientation) in orientations {
            rotate(to: orientation)
            assertRunning(app, "rotating to \(name)")
            IOSTest.capture(name, in: self)
        }
    }

    func testKeyboardShortcutsSwitchTabs() {
        let app = enterDemo()
        for (suffix, orientation) in [("portrait", UIDeviceOrientation.portrait), ("landscape", .landscapeLeft)] {
            rotate(to: orientation)
            press(app, "2", .command, "Command-2 in \(suffix)")
            IOSTest.capture("\(suffix)-01-library", in: self)
            press(app, "3", .command, "Command-3 in \(suffix)")
            IOSTest.capture("\(suffix)-02-downloads", in: self)
            press(app, "4", .command, "Command-4 in \(suffix)")
            IOSTest.capture("\(suffix)-03-you", in: self)
            press(app, "1", .command, "Command-1 in \(suffix)")
            XCTAssertTrue(IOSTest.wait(for: homeTitle(app), "exists == true", timeout: 20), "Command-1 did not return to Home in \(suffix)")
            IOSTest.capture("\(suffix)-04-home", in: self)
            press(app, "f", .command, "Command-F in \(suffix)")
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 30), "Command-F did not open Search in \(suffix)")
            XCTAssertTrue(IOSTest.wait(for: field, "hasKeyboardFocus == true", timeout: 10), "Command-F left the search field without keyboard focus in \(suffix)")
            XCTAssertTrue(hasKeyboardFocus(field), "the search field has no keyboard focus in \(suffix)")
            IOSTest.capture("\(suffix)-05-search", in: self)
            press(app, "1", .command, "Command-1 leaving Search in \(suffix)")
        }
    }

    func testSidebarListsEachLibrary() {
        let app = enterDemo()
        rotate(to: .landscapeLeft)
        revealSidebar(app)
        IOSTest.capture("01-sidebar", in: self)
        XCTAssertNotNil(libraryEntry(app, ["Movies"]), "the sidebar has no Movies library")
        let shows = libraryEntry(app, ["TV Shows", "Shows"])
        XCTAssertNotNil(shows, "the sidebar has no TV Shows library")
        guard let shows else { return }
        let title = shows.label
        shows.tap()
        IOSTest.settle(3)
        assertRunning(app, "choosing \(title)")
        IOSTest.capture("02-tv-shows", in: self)
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 20), "the navigation title never showed \(title)")
    }

    func testCommandHoldOverlayDoesNotCrash() {
        let app = enterDemo()
        rotate(to: .landscapeLeft)
        press(app, "r", .command, "Command-R on Home")
        IOSTest.capture("01-after-refresh", in: self)

        guard let movies = libraryEntry(app, ["Movies"]) else {
            XCTFail("the sidebar has no Movies library")
            return
        }
        movies.tap()
        IOSTest.settle(3)
        IOSTest.capture("02-movies-library", in: self)
        let poster = app.cells.containing(NSPredicate(format: "label CONTAINS 'Cold Meridian'")).firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 60), "the Movies library shows no poster to open")
        poster.tap()
        XCTAssertTrue(backButton(app).waitForExistence(timeout: 30), "tapping a poster did not push a detail")
        IOSTest.settle(2)
        IOSTest.capture("02-detail", in: self)

        press(app, "[", .command, "Command-[ on the detail")
        XCTAssertTrue(IOSTest.wait(for: backButton(app), "exists == false", timeout: 20), "Command-[ did not pop the detail")
        IOSTest.capture("03-after-back", in: self)
    }

    /// XCUITest's synthesized Escape never reaches the player, so closing it with Escape is checked by hand on a real keyboard.
    func testSpaceResumesTheHero() {
        let app = enterDemo()
        press(app, " ", [], "Space on Home")
        XCTAssertTrue(IOSTest.wait(for: homeTitle(app), "hittable == false", timeout: 60), "Space did not open the player")
        IOSTest.settle(3)
        assertRunning(app, "playing from Space")
        IOSTest.capture("01-playing", in: self)
    }
}
