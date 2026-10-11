import XCTest

@MainActor
final class GalleryTests: TVTestCase {
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

    func testHostMenuPopsWhileLoading() {
        let app = launchGallery(style: "dark", mode: "host")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "host.row.loading"))
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        TVTest.capture("01-loading-pushed", in: self)
        TVTest.remote.press(.menu)
        XCTAssertTrue(app.descendants(matching: .any)["host.row.loading"].waitForExistence(timeout: 5), "Menu while loading left the screen or the app instead of popping")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "host.row.loading"))
        TVTest.capture("02-popped-to-root", in: self)
    }

    func testHostErrorRecoversThroughRetryAndKeepsFocusOnTheScreen() {
        let app = launchGallery(style: "dark", mode: "host")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "host.row.loading"))
        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "host.row.error"))
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        TVTest.capture("01-error", in: self)
        XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 5))
        TVTest.remote.press(.select)
        TVTest.settle(0.6)
        TVTest.capture("02-retrying", in: self)
        TVTest.remote.press(.menu)
        XCTAssertTrue(app.descendants(matching: .any)["host.row.error"].waitForExistence(timeout: 5), "focus left the screen after Try Again, so Menu did not pop")
        TVTest.remote.press(.select)
        XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 5))
        TVTest.remote.press(.select)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "host.item.0", timeout: 15), "focus did not return to the content after the retry")
        TVTest.capture("03-recovered", in: self)
    }

    func testHostFocusSurvivesAReloadThatShiftsItems() {
        let app = launchGallery(style: "dark", mode: "host")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "host.row.loading"))
        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "host.row.content"))
        TVTest.remote.press(.select)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "host.item.0", timeout: 10))
        for _ in 0..<3 { TVTest.remote.press(.right) }
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "host.item.3"))
        TVTest.remote.press(.playPause)
        TVTest.settle(1.5)
        XCTAssertTrue(app.descendants(matching: .any)["host.new.0"].exists, "Play/Pause was not handled by the screen")
        TVTest.remote.press(.select)
        XCTAssertTrue(app.staticTexts["host.depth"].waitForExistence(timeout: 5))
        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "host.item.3", timeout: 8), "focus came back to a different item after the list shifted")
        TVTest.capture("01-restored", in: self)
    }

    func testDoublePushMakesOneScreen() {
        let app = launchGallery(style: "dark", mode: "host")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "host.row.loading"))
        for _ in 0..<3 { TVTest.remote.press(.down) }
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "host.row.doublePush"))
        TVTest.remote.press(.select)
        let depth = app.staticTexts["host.depth"]
        XCTAssertTrue(depth.waitForExistence(timeout: 5))
        XCTAssertEqual(depth.label, "Depth 2")
    }

    func testImagesRetryAfterAFailedLoad() {
        let app = launchGallery(style: "dark", mode: "images")
        XCTAssertTrue(app.descendants(matching: .any)["images.card.0"].waitForExistence(timeout: 15))
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "images.card.0"))
        TVTest.settle(2.5)
        TVTest.capture("01-first-load-failed", in: self)
        let log = app.staticTexts["images.log"]
        XCTAssertTrue(log.label.contains("flaky-poster/dawn FAILED"), log.label)
        TVTest.remote.press(.playPause)
        TVTest.settle(3.0)
        TVTest.capture("02-after-retry", in: self)
        let lines = log.label.split(separator: "\n").filter { $0.contains("flaky-poster/dawn") }
        XCTAssertEqual(lines.count, 2, "the poster was not requested again: \(log.label)")
        XCTAssertFalse(lines.last?.contains("FAILED") ?? true)
        XCTAssertEqual(log.label.split(separator: "\n").filter { $0.contains("flaky-backdrop/dawn") }.count, 2, "the backdrop was not requested again: \(log.label)")
        TVTest.remote.press(.playPause)
        TVTest.settle(3.0)
        TVTest.capture("03-poster-as-backdrop", in: self)
        XCTAssertTrue(log.label.contains("poster 720px poster/solo"), log.label)
    }

    func testHeroFitsItsBlockAndIsOneAccessibilityElement() {
        let app = launchGallery(style: "dark", mode: "hero-long")
        let info = app.descendants(matching: .any)["hero.info"]
        XCTAssertTrue(info.waitForExistence(timeout: 15))
        TVTest.settle(2.0)
        TVTest.capture("01-hero-long", in: self)
        let header = app.staticTexts["Recently Added"]
        XCTAssertTrue(header.exists)
        XCTAssertLessThanOrEqual(info.frame.maxY, header.frame.minY, "hero block overlaps the shelf header: \(info.frame) vs \(header.frame)")
        XCTAssertGreaterThanOrEqual(info.frame.minY, 0)
        XCTAssertTrue(info.label.contains("Extraordinarily"))
        XCTAssertEqual(info.value as? String, "38 percent watched")
    }

    func testHeroVariants() {
        for (mode, name) in [("hero-short", "01-short"), ("hero-title1", "02-title1")] {
            let app = launchGallery(style: "dark", mode: mode)
            XCTAssertTrue(app.descendants(matching: .any)["hero.info"].waitForExistence(timeout: 15))
            TVTest.settle(2.0)
            TVTest.capture(name, in: self)
            let info = app.descendants(matching: .any)["hero.info"]
            let header = app.staticTexts["Recently Added"]
            XCTAssertLessThanOrEqual(info.frame.maxY, header.frame.minY, "\(mode): \(info.frame) vs \(header.frame)")
            app.terminate()
        }
    }

    func testScreenTitleIsOneHeaderBelowTheTabBar() {
        for (mode, identifier, expected) in [
            ("title-cell", "title.cell", "Watch History. 12 plays this week · 8h 40m"),
            ("title-header", "tv.screenTitle", "Genre: Documentary. 94 titles. Everything in your libraries filed under Documentary, newest first."),
        ] {
            let app = launchGallery(style: "dark", mode: mode)
            TVTest.settle(2.5)
            TVTest.capture("01-\(mode)", in: self)
            let title = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", expected)).firstMatch
            XCTAssertTrue(title.exists, "\(mode): no single accessibility element reads \(expected)")
            let first = app.descendants(matching: .any)["title.poster.0"]
            XCTAssertTrue(first.waitForExistence(timeout: 10))
            XCTAssertGreaterThanOrEqual(title.frame.minY, 0)
            XCTAssertLessThan(title.frame.maxY, first.frame.minY, "\(mode): the title overlaps the shelf")
            app.terminate()
        }
    }

    func testScreenTitleInLight() {
        let app = launchGallery(style: "light", mode: "title-header")
        TVTest.settle(2.5)
        TVTest.capture("01-title-header-light", in: self)
        XCTAssertTrue(app.descendants(matching: .any)["title.poster.0"].waitForExistence(timeout: 10))
    }

    func testReadOnlyPanelIsAFocusStopOnlyForVoiceOver() {
        let plain = TVTest.launch(extraEnvironment: ["CRUCIBLE_GALLERY": "panel", "CRUCIBLE_GALLERY_STYLE": "dark"])
        XCTAssertTrue(TVTest.waitForFocus(on: plain, identifier: "panel.button"))
        TVTest.remote.press(.up)
        TVTest.settle(1.0)
        XCTAssertTrue(TVTest.waitForFocus(on: plain, identifier: "panel.button", timeout: 2), "the panel took focus without VoiceOver")
        TVTest.capture("01-without-voiceover", in: self)
        plain.terminate()

        let spoken = TVTest.launch(extraEnvironment: ["CRUCIBLE_GALLERY": "panel", "CRUCIBLE_GALLERY_STYLE": "dark", "CRUCIBLE_VOICEOVER": "1"])
        XCTAssertTrue(TVTest.waitForFocus(on: spoken, identifier: "panel.button"))
        TVTest.remote.press(.up)
        XCTAssertTrue(TVTest.waitForFocus(on: spoken, identifier: "panel.readonly", timeout: 5), "the panel is not a focus stop while VoiceOver runs")
        TVTest.settle(1.0)
        TVTest.capture("02-with-voiceover", in: self)
        let panel = spoken.descendants(matching: .any)["panel.readonly"]
        XCTAssertEqual(panel.label, "Marcus, connected locally to Marcus-PC, Plex Pass")
    }

    private func launchGallery(style: String, mode: String = "1") -> XCUIApplication {
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_GALLERY": mode, "CRUCIBLE_GALLERY_STYLE": style])
        if mode == "1" {
            XCTAssertTrue(app.descendants(matching: .any)["gallery.continueWatching.0"].waitForExistence(timeout: 20))
            TVTest.settle(2.0)
        } else if mode == "host" {
            XCTAssertTrue(app.descendants(matching: .any)["host.row.loading"].waitForExistence(timeout: 20))
            TVTest.settle(1.0)
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

        step(app, .down, until: "tv.chip.helpers")
        TVTest.remote.press(.right)
        TVTest.settle(0.6)
        TVTest.remote.press(.select)
        TVTest.settle(0.9)
        TVTest.capture("14b-helpers-chip-row", in: self)
        step(app, .down, until: "gallery.helpers.menu")
        TVTest.capture("14c-helpers-menu-button", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        TVTest.capture("14d-helpers-menu-open", in: self)
        let year = app.descendants(matching: .any)["Year"]
        XCTAssertTrue(year.waitForExistence(timeout: 3))
        TVTest.remote.press(.down)
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        XCTAssertTrue(app.buttons["Sort: Year"].exists || app.descendants(matching: .any)["Sort: Year"].exists, "menu selection did not update the button in place")
        step(app, .down, until: "gallery.helpers.alert")
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        TVTest.capture("14e-helpers-alert", in: self)
        TVTest.remote.press(.menu)
        TVTest.settle(1.0)
        TVTest.capture("14f-after-alert", in: self)
        step(app, .down, until: "gallery.settings.")
        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        focus(app, "gallery.settings.2")
        TVTest.capture("15-row-focused", in: self)

        step(app, .down, until: "gallery.surface.tile", attempts: 6)
        TVTest.remote.press(.select)
        TVTest.settle(0.8)
        TVTest.capture("16-surface-focused", in: self)
        let tile = app.descendants(matching: .any)["gallery.surface.tile"]
        XCTAssertEqual(tile.value as? String, "Selected 1 time", "Select did not trigger the surface action exactly once")

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
            trail.append("\(identifier)|\(app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch.label)")
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
