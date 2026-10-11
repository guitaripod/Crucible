import XCTest

@MainActor
final class GalleryTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testGalleryDark() {
        walkGallery(style: "dark")
    }

    func testGalleryLight() {
        walkGallery(style: "light")
    }

    func testContextMenuOnLongPress() {
        let app = launchGallery(style: "dark")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "gallery.continueWatching.0"))
        TVTest.remote.press(.right)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "gallery.continueWatching.1"))
        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1.0)
        TVTest.capture("01-context-menu", in: self)
        XCTAssertTrue(app.descendants(matching: .any)["Mark Watched"].waitForExistence(timeout: 3), "context menu did not appear")
        TVTest.remote.press(.menu)
        TVTest.settle(0.8)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "gallery.continueWatching.1"), "focus not restored after the menu closed")
    }

    func testStateScreens() {
        for (mode, name) in [("state-loading", "01-loading"), ("state-empty", "02-empty"), ("state-error", "03-error")] {
            let app = launchGallery(style: "dark", mode: mode)
            TVTest.settle(2.5)
            TVTest.capture(name, in: self)
            app.terminate()
        }
    }

    private func launchGallery(style: String, mode: String = "1") -> XCUIApplication {
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_GALLERY": mode, "CRUCIBLE_GALLERY_STYLE": style])
        if mode == "1" {
            XCTAssertTrue(app.descendants(matching: .any)["gallery.continueWatching.0"].waitForExistence(timeout: 20))
            TVTest.settle(2.0)
        }
        return app
    }

    private func walkGallery(style: String) {
        let app = launchGallery(style: style)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "gallery.continueWatching.0"))
        TVTest.settle(1.5)
        TVTest.capture("01-initial", in: self)

        TVTest.remote.press(.right)
        focus(app, "gallery.continueWatching.1")
        TVTest.capture("02-landscape-focused", in: self)

        step(app, .down, until: "tv.sectionHeader.seeAll")
        TVTest.capture("03-see-all-focused", in: self)
        step(app, .down, until: "gallery.recentlyAdded.1")
        TVTest.capture("04-poster-progress-focused", in: self)
        TVTest.remote.press(.right)
        focus(app, "gallery.recentlyAdded.2")
        TVTest.capture("05-poster-watched-focused", in: self)
        TVTest.remote.press(.right)
        focus(app, "gallery.recentlyAdded.3")
        TVTest.capture("06-poster-badge-focused", in: self)

        step(app, .down, until: "gallery.episodes.")
        TVTest.capture("07-episode-focused", in: self)
        step(app, .down, until: "gallery.cast.")
        TVTest.capture("08-person-focused", in: self)
        step(app, .down, until: "gallery.genres.")
        TVTest.capture("09-genre-focused", in: self)
        step(app, .down, until: "gallery.libraries.")
        TVTest.capture("10-library-focused", in: self)

        step(app, .down, until: "tv.chip.")
        TVTest.remote.press(.right)
        TVTest.settle(0.6)
        TVTest.capture("11-chip-focused", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(0.9)
        TVTest.capture("12-chip-selected", in: self)

        step(app, .down, until: "gallery.button.")
        step(app, .left, until: "gallery.button.0", attempts: 6)
        TVTest.capture("13-primary-button-focused", in: self)
        TVTest.remote.press(.right)
        focus(app, "gallery.button.1")
        TVTest.capture("14-glass-button-focused", in: self)

        step(app, .down, until: "gallery.settings.")
        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        focus(app, "gallery.settings.2")
        TVTest.capture("15-row-focused", in: self)

        step(app, .down, until: "gallery.surface.tile", attempts: 6)
        TVTest.capture("16-surface-focused", in: self)

        step(app, .down, until: "gallery.grid.")
        TVTest.capture("17-grid-focused", in: self)
        TVTest.remote.press(.down)
        TVTest.settle(1.2)
        TVTest.capture("18-grid-second-row-focused", in: self)

        TVTest.remote.press(.down)
        TVTest.settle(1.5)
        TVTest.capture("19-states-focused", in: self)
        TVTest.remote.press(.right)
        TVTest.settle(1.5)
        TVTest.capture("20-states-error-focused", in: self)
    }

    private func focus(_ app: XCUIApplication, _ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: identifier, timeout: 8), "focus never reached \(identifier); focused: \(focusedIdentifier(app))", file: file, line: line)
        TVTest.settle(1.0)
    }

    private func step(_ app: XCUIApplication, _ button: XCUIRemote.Button, until prefix: String, attempts: Int = 4, file: StaticString = #filePath, line: UInt = #line) {
        var trail: [String] = []
        var reached = false
        for _ in 0..<attempts {
            TVTest.remote.press(button)
            TVTest.settle(0.6)
            let identifier = focusedIdentifier(app)
            trail.append(identifier)
            if identifier.hasPrefix(prefix) {
                reached = true
                break
            }
        }
        XCTAssertTrue(reached, "focus never reached \(prefix); trail: \(trail)", file: file, line: line)
        TVTest.settle(1.0)
    }

    private func focusedIdentifier(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch.identifier
    }
}
