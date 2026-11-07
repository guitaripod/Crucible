import XCTest

/// Subtitles in the player, against the mock, which hands the selected text subtitle over as a WebVTT rendition the way a real
/// server does. The transport bar has one Subtitles menu: Off and the subtitle in the stream switch at once without a new stream,
/// another language asks the server for one, and the menu's check mark always names what is on screen.
@MainActor
final class SubtitleTests: TVTestCase {
    private static let english = "English (SRT)"
    private static let finnish = "Finnish (SRT)"

    override func setUp() {
        continueAfterFailure = false
    }

    func testTheSubtitlesMenuTogglesTheTrackAtOnceAndSwitchesLanguage() throws {
        let app = TVTest.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60), "the main UI never appeared")
        TVTest.settle(1.5)
        let movie = openFirstMovie(in: app)
        pickOnDetail(Self.english, in: app)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.otherElements["player.view"].waitForExistence(timeout: 30), "the player never appeared")
        TVTest.settle(7)
        TVTest.capture("01-english", in: self)
        let streams = try requests("start.m3u8")
        XCTAssertEqual(try requests("subtitleStreamID=\(movie * 10 + 5)"), 1, "the server was not told to send English")

        openSubtitleControls(in: app)
        pick("Off", checked: Self.english, in: app)
        TVTest.settle(1.5)
        TVTest.capture("02-off", in: self)
        XCTAssertTrue(waitForRequests("subtitleStreamID=0", count: 1), "the server was not told subtitles are off")
        pick(Self.english, checked: "Off", in: app)
        TVTest.settle(1.5)
        XCTAssertEqual(try requests("start.m3u8"), streams, "showing or hiding the subtitle in the stream asked for a new stream")

        pick(Self.finnish, checked: Self.english, in: app)
        XCTAssertTrue(waitForRequests("start.m3u8", count: streams + 1), "another language never asked for a new stream")
        XCTAssertEqual(try requests("subtitleStreamID=\(movie * 10 + 8)"), 1, "the server was not told to send Finnish")
        TVTest.settle(2)
        TVTest.remote.press(.playPause)
        TVTest.settle(2.5)
        TVTest.capture("03-finnish", in: self)
        TVTest.remote.press(.playPause)
        TVTest.settle(1.5)
        openSubtitleControls(in: app)
        pick("Off", checked: Self.finnish, in: app)
        TVTest.settle(1.5)
        XCTAssertEqual(try requests("start.m3u8"), streams + 1, "turning the new subtitle off asked for a new stream")
    }

    /// Opens the first poster of the Movies grid and returns its rating key.
    private func openFirstMovie(in app: XCUIApplication) -> Int {
        AppNavigation.selectTab("Movies", in: app)
        XCTAssertTrue(AppNavigation.firstElement(app, prefix: "tv.library.media.").waitForExistence(timeout: 30), "Movies showed no grid")
        TVTest.settle(1.5)
        XCTAssertTrue(AppNavigation.move(app, .down, untilFocusHasPrefix: "tv.library.media.", limit: 6), "focus never reached the grid")
        let key = Int(AppNavigation.focusedIdentifier(app).replacingOccurrences(of: "tv.library.media.", with: "")) ?? 0
        TVTest.remote.press(.select)
        XCTAssertTrue(AppNavigation.detailPrimary(app).waitForExistence(timeout: 30), "the detail screen never appeared")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "detail.action.primary", timeout: 10))
        TVTest.settle(1)
        return key
    }

    /// Picks `label` in the detail screen's Subtitles menu and comes back to Play.
    private func pickOnDetail(_ label: String, in app: XCUIApplication) {
        XCTAssertTrue(AppNavigation.move(app, .right, untilFocusHasPrefix: "detail.action.subtitles", limit: 8), "focus never reached Subtitles")
        TVTest.remote.press(.select)
        TVTest.settle(1.2)
        XCTAssertTrue(focusMenuItem(label, in: app), "the detail's Subtitles menu has no \(label)")
        TVTest.remote.press(.select)
        TVTest.settle(1.2)
        XCTAssertTrue(AppNavigation.move(app, .left, untilFocusHasPrefix: "detail.action.primary", limit: 8))
    }

    /// Pauses, which brings up the transport bar, and moves the focus to its Subtitles button: up from the scrubber, then past
    /// Audio, the first of the app's buttons.
    private func openSubtitleControls(in app: XCUIApplication) {
        TVTest.remote.press(.playPause)
        TVTest.settle(1.5)
        TVTest.remote.press(.up)
        TVTest.settle(0.8)
        for _ in 0..<6 {
            TVTest.remote.press(.left)
            TVTest.settle(0.3)
        }
        TVTest.remote.press(.right)
        TVTest.settle(0.6)
    }

    /// Opens the Subtitles menu, checks that `checked` is the ticked row, and picks `label`.
    private func pick(_ label: String, checked: String, in app: XCUIApplication) {
        TVTest.remote.press(.select)
        TVTest.settle(1.2)
        XCTAssertTrue(app.staticTexts["Subtitles"].waitForExistence(timeout: 5), "the Subtitles menu did not open")
        let ticked = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'selected, '")).allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(ticked.count == 1 && Self.names(ticked[0], checked), "the menu ticks \(ticked), not \(checked)")
        XCTAssertTrue(focusMenuItem(label, in: app), "the Subtitles menu has no \(label)")
        TVTest.remote.press(.select)
    }

    /// Presses Down until the open menu's row titled `label` has the focus. A row takes the focus either labelled itself or as an
    /// unlabelled cell whose text carries the title.
    private func focusMenuItem(_ label: String, in app: XCUIApplication) -> Bool {
        for _ in 0..<8 {
            let focused = AppNavigation.focusedElement(app)
            if Self.names(focused.label, label) || focused.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")).count > 0 { return true }
            TVTest.remote.press(.down)
            TVTest.settle(0.4)
        }
        return false
    }

    /// Whether a menu row's accessibility label (its title, its detail line, and "selected" when ticked) is the row titled `title`.
    private static func names(_ label: String, _ title: String) -> Bool {
        let bare = label.hasPrefix("selected, ") ? String(label.dropFirst("selected, ".count)) : label
        return bare == title || bare.hasPrefix(title + ",")
    }

    private func requests(_ needle: String) throws -> Int {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"])
        var components = try XCTUnwrap(URLComponents(string: base + "/mock/requests"))
        components.queryItems = [URLQueryItem(name: "contains", value: needle)]
        let data = try XCTUnwrap(TVTest.fetch(try XCTUnwrap(components.url)))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Int]
        return try XCTUnwrap(object?["count"])
    }

    private func waitForRequests(_ needle: String, count: Int, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? requests(needle)) ?? 0 >= count { return true }
            TVTest.settle(0.5)
        }
        return false
    }
}
