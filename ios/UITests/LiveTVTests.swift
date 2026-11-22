import XCTest

/// Live TV on iPhone against the mock server: Plex's free channels and the antenna tuner in the guide, the Beta note, a
/// channel playing, a recording scheduled, and a channel playlist added whose bare transport stream plays through the relay.
/// It runs only when `CRUCIBLE_PHONE_MOCK` names the running mock (`tv.sh mock-up` prints it).
@MainActor
final class LiveTVTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() throws -> (XCUIApplication, String) {
        guard let mock = ProcessInfo.processInfo.environment["CRUCIBLE_PHONE_MOCK"] else {
            throw XCTSkip("Needs the mock server named in CRUCIBLE_PHONE_MOCK")
        }
        _ = URL(string: mock + "/mock/reset").flatMap { try? Data(contentsOf: $0) }
        let app = IOSTest.launch(extraEnvironment: ["CRUCIBLE_PHONE_MOCK": mock, "CRUCIBLE_PLEXTV": mock])
        return (app, mock)
    }

    private func openLiveTV(_ app: XCUIApplication) {
        let you = IOSTest.tab(app, "You")
        XCTAssertTrue(you.waitForExistence(timeout: 60), "the tab bar never appeared")
        you.tap()
        let row = IOSTest.element(app, "you.liveTV")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "You offers Live TV")
        row.tap()
        XCTAssertTrue(IOSTest.element(app, "livetv.guide").waitForExistence(timeout: 20), "the guide opens")
    }

    private func labelled(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func programs(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "livetv.program")
    }

    func testTheGuideShowsFreeAndTunerChannelsAndTheBetaNoteExplainsIt() throws {
        let (app, _) = try launch()
        openLiveTV(app)
        XCTAssertTrue(labelled(app, "Marren Public").waitForExistence(timeout: 30), "the server's antenna channels are listed")
        IOSTest.element(app, "livetv.filter").tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Plex Channels'")).firstMatch.waitForExistence(timeout: 10), "Plex's free channels are a source")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'All Channels'")).firstMatch.tap()
        XCTAssertTrue(IOSTest.wait(for: programs(app).firstMatch, "exists == true", timeout: 30), "airings load into the guide")
        IOSTest.settle(2)
        IOSTest.capture("01-guide", in: self)
        let beta = IOSTest.element(app, "livetv.beta")
        XCTAssertTrue(beta.exists, "the title carries a Beta tag")
        beta.tap()
        let note = IOSTest.element(app, "livetv.beta.note")
        XCTAssertTrue(note.waitForExistence(timeout: 10), "the Beta tag opens its note")
        XCTAssertTrue(labelled(app, "every Plex account").exists, "the note says what Live TV does")
        IOSTest.settle(1)
        IOSTest.capture("02-beta-note", in: self)
        IOSTest.element(app, "livetv.beta.dismiss").tap()
        XCTAssertTrue(IOSTest.wait(for: note, "exists == false", timeout: 10), "Got It closes the note")
    }

    func testAChannelPlaysAndChangesChannel() throws {
        let (app, _) = try launch()
        openLiveTV(app)
        XCTAssertTrue(IOSTest.wait(for: programs(app).firstMatch, "exists == true", timeout: 30))
        IOSTest.settle(2)
        IOSTest.element(app, "livetv.info").tap()
        XCTAssertTrue(IOSTest.element(app, "livetv.player").waitForExistence(timeout: 15), "the player opens")
        IOSTest.settle(8)
        IOSTest.capture("03-playing", in: self)
        let up = IOSTest.element(app, "livetv.channelUp")
        if !up.isHittable { app.tap() }
        XCTAssertTrue(up.waitForExistence(timeout: 5), "the player offers Channel Up")
        up.tap()
        IOSTest.settle(6)
        IOSTest.capture("04-channel-up", in: self)
    }

    func testARecordingIsScheduledFromAnAiringToCome() throws {
        let (app, _) = try launch()
        openLiveTV(app)
        let filter = IOSTest.element(app, "livetv.filter")
        XCTAssertTrue(filter.waitForExistence(timeout: 20))
        filter.tap()
        let antenna = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Antenna'")).firstMatch
        XCTAssertTrue(antenna.waitForExistence(timeout: 10), "each source is a filter")
        antenna.tap()
        XCTAssertTrue(IOSTest.wait(for: programs(app).element(boundBy: 2), "exists == true", timeout: 30))
        IOSTest.settle(2)
        programs(app).element(boundBy: 1).tap()
        let record = app.buttons["Record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), "an airing to come offers Record")
        record.tap()
        let episode = app.buttons["Record This Episode"]
        XCTAssertTrue(episode.waitForExistence(timeout: 15), "the server's choices are offered")
        IOSTest.capture("05-record-options", in: self)
        episode.tap()
        XCTAssertTrue(app.alerts["Recording scheduled"].waitForExistence(timeout: 15), "the recording is scheduled")
        app.alerts.buttons.firstMatch.tap()
        let actions = IOSTest.element(app, "livetv.actions")
        actions.tap()
        app.buttons["Recordings"].tap()
        XCTAssertTrue(IOSTest.element(app, "livetv.recordings").waitForExistence(timeout: 15))
        IOSTest.settle(2)
        IOSTest.capture("06-recordings", in: self)
    }

    func testAPlaylistIsAddedAndItsTransportStreamPlays() throws {
        let (app, mock) = try launch()
        openLiveTV(app)
        let actions = IOSTest.element(app, "livetv.actions")
        XCTAssertTrue(actions.waitForExistence(timeout: 20))
        actions.tap()
        app.buttons["Channel Playlists"].tap()
        let add = IOSTest.element(app, "livetv.addPlaylist")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(mock + "/mock/livetv/playlist.m3u")
        app.alerts.buttons["Add"].tap()
        let added = app.alerts.matching(NSPredicate(format: "label CONTAINS '4 channels'")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 30), "the playlist is read and its channels counted")
        IOSTest.capture("07-playlist-added", in: self)
        added.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        let filter = IOSTest.element(app, "livetv.filter")
        XCTAssertTrue(filter.waitForExistence(timeout: 15))
        filter.tap()
        let playlist = app.buttons.matching(NSPredicate(format: "label CONTAINS '127.0.0.1'")).firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 15), "the playlist is a source to filter by")
        playlist.tap()
        XCTAssertTrue(labelled(app, "Lighthouse One").waitForExistence(timeout: 30), "the playlist's channels join the guide")
        IOSTest.settle(3)
        IOSTest.capture("08-guide-with-playlist", in: self)
        let lighthouse = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '101'")).firstMatch
        XCTAssertTrue(lighthouse.waitForExistence(timeout: 10))
        let row = lighthouse.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: row.maxX + 60, dy: row.midY)).tap()
        XCTAssertTrue(IOSTest.element(app, "livetv.player").waitForExistence(timeout: 30), "the playlist's channel opens in the player")
        IOSTest.settle(12)
        IOSTest.capture("09-transport-stream-playing", in: self)
        XCTAssertFalse(app.alerts.firstMatch.exists, "the transport stream plays through the relay without an error")
    }

    func testSearchFindsAChannelAndPlaysIt() throws {
        let (app, _) = try launch()
        openLiveTV(app)
        var field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 3) {
            app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Search' OR identifier == 'livetv.search'")).firstMatch.tap()
            field = app.searchFields.firstMatch
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Live TV offers search")
        field.tap()
        field.typeText("marren")
        let hit = IOSTest.element(app, "livetv.search.results").descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Marren Public'")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 30), "the channel is found by its name")
        IOSTest.settle(1)
        IOSTest.capture("10-search", in: self)
        hit.tap()
        XCTAssertTrue(IOSTest.element(app, "livetv.player").waitForExistence(timeout: 30), "a found channel plays")
    }
}
