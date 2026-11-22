import XCTest

/// Live TV on the Apple TV against the mock server (`CRUCIBLE_PLEXTV` pointing plex.tv at the mock for its free channels):
/// the guide through the focus engine, the Beta note, a channel playing with the transport bar's channel controls, and a
/// recording scheduled from an airing to come.
@MainActor
final class LiveTVTests: TVTestCase {
    private func labelled(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func openLiveTV() -> XCUIApplication {
        let mock = ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"] ?? ""
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_STYLE": "dark", "CRUCIBLE_PLEXTV": mock])
        AppNavigation.selectTab("Live TV", in: app)
        XCTAssertTrue(AppNavigation.element(app, "livetv.guide").waitForExistence(timeout: 30), "the guide opens")
        XCTAssertTrue(labelled(app, "Marren Public").waitForExistence(timeout: 30), "the server's antenna channels are listed")
        XCTAssertTrue(app.descendants(matching: .any)["Sources"].exists, "several sources (the antenna and Plex's free channels) offer a Sources filter")
        XCTAssertTrue(TVTest.waitForFocus(app.cells.matching(identifier: "livetv.program").firstMatch, timeout: 30), "the focus lands in the guide")
        TVTest.settle(2)
        return app
    }

    func testTheGuideMovesAiringByAiringAndShowsTheTuner() {
        let app = openLiveTV()
        TVTest.capture("01-guide", in: self)
        TVTest.remote.press(.right)
        TVTest.settle(0.6)
        TVTest.remote.press(.down)
        TVTest.settle(0.6)
        TVTest.capture("02-moved", in: self)
        XCTAssertTrue(labelled(app, "Marren Public").exists || labelled(app, "Vale Four").exists, "the antenna's channels are in the guide")
        TVTest.capture("03-tuner-channels", in: self)
    }

    func testTheBetaTagOpensItsNote() {
        let app = openLiveTV()
        TVTest.remote.press(.up)
        TVTest.settle(0.8)
        for _ in 0..<8 {
            TVTest.remote.press(.left)
            TVTest.settle(0.3)
        }
        TVTest.remote.press(.up)
        TVTest.settle(0.8)
        XCTAssertEqual(AppNavigation.focusedIdentifier(app), "livetv.beta", "the Beta tag takes the focus")
        TVTest.remote.press(.select)
        XCTAssertTrue(AppNavigation.element(app, "livetv.beta.note").waitForExistence(timeout: 10), "the note opens")
        TVTest.settle(1)
        TVTest.capture("04-beta-note", in: self)
        TVTest.remote.press(.select)
        XCTAssertTrue(TVTest.waitForNoElement(AppNavigation.element(app, "livetv.beta.note"), timeout: 10), "Got It closes it")
    }

    func testAChannelPlaysAndTheTransportBarChangesChannel() {
        let app = openLiveTV()
        TVTest.remote.press(.select)
        XCTAssertTrue(AppNavigation.element(app, "livetv.player").waitForExistence(timeout: 30), "the player opens")
        TVTest.settle(8)
        TVTest.capture("05-playing", in: self)
        TVTest.remote.press(.down)
        TVTest.settle(2)
        TVTest.capture("06-transport", in: self)
        AppNavigation.leavePlayer(app)
    }

    func testARecordingIsScheduledFromAnAiringToCome() {
        let app = openLiveTV()
        TVTest.remote.press(.right)
        TVTest.settle(0.6)
        TVTest.remote.press(.right)
        TVTest.settle(0.8)
        TVTest.remote.press(.select)
        let record = app.buttons["Record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 10), "an airing to come on the tuner offers Record")
        TVTest.capture("07-airing-actions", in: self)
        for _ in 0..<4 where !record.hasFocus {
            TVTest.remote.press(.down)
            TVTest.settle(0.4)
        }
        TVTest.remote.press(.select)
        let episode = app.buttons["Record This Episode"].firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 15), "the server's choices are offered")
        TVTest.settle(0.8)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.alerts["Recording scheduled"].waitForExistence(timeout: 15), "the recording is scheduled")
        TVTest.capture("08-scheduled", in: self)
        TVTest.remote.press(.select)
    }

    func testSearchFindsAChannel() {
        let app = openLiveTV()
        TVTest.remote.press(.up)
        TVTest.settle(0.8)
        for _ in 0..<8 {
            TVTest.remote.press(.left)
            TVTest.settle(0.3)
        }
        XCTAssertEqual(AppNavigation.focusedIdentifier(app), "tv.chip.search", "Search is the first filter")
        TVTest.remote.press(.select)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "the search screen opens")
        field.typeText("marren")
        let hit = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Marren Public'")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 30), "the channel is found by its name")
        TVTest.settle(1)
        TVTest.capture("09-search", in: self)
    }
}
