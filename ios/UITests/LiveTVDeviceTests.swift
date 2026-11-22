import XCTest

/// Live TV on a real iPhone with the session already on it (no mock, so a real Plex account and real streams): Plex's free
/// channels playing through AVPlayer, and a channel playlist whose bare transport stream plays through the on-device relay.
/// Runs only with `CRUCIBLE_DEVICE_LIVE=1`; the playlist test also needs `CRUCIBLE_DEVICE_PLAYLIST`, an M3U address the phone
/// can reach, and removes the playlist again at the end.
@MainActor
final class LiveTVDeviceTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["CRUCIBLE_DEVICE_LIVE"] == "1" else {
            throw XCTSkip("Runs on a signed-in device with CRUCIBLE_DEVICE_LIVE=1")
        }
        return IOSTest.launch(fresh: false)
    }

    private func openLiveTV(_ app: XCUIApplication) {
        let you = IOSTest.tab(app, "You")
        XCTAssertTrue(you.waitForExistence(timeout: 60), "the tab bar never appeared")
        you.tap()
        let row = IOSTest.element(app, "you.liveTV")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "You offers Live TV")
        row.tap()
        XCTAssertTrue(IOSTest.element(app, "livetv.guide").waitForExistence(timeout: 30), "the guide opens")
    }

    private func choose(_ app: XCUIApplication, source text: String) {
        let filter = IOSTest.element(app, "livetv.filter")
        XCTAssertTrue(filter.waitForExistence(timeout: 30))
        filter.tap()
        let source = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 30), "\(text) is a source to filter by")
        source.tap()
    }

    private func programs(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "livetv.program")
    }

    private func assertPlays(_ app: XCUIApplication, _ name: String) {
        XCTAssertTrue(IOSTest.element(app, "livetv.player").waitForExistence(timeout: 30), "the player opens")
        IOSTest.settle(20)
        IOSTest.capture(name, in: self)
        XCTAssertFalse(app.alerts.firstMatch.exists, "the channel plays without an error")
    }

    func testAPlexFreeChannelPlaysAndChangesChannel() throws {
        let app = try launch()
        openLiveTV(app)
        choose(app, source: "Plex Channels")
        XCTAssertTrue(IOSTest.wait(for: programs(app).firstMatch, "exists == true", timeout: 60), "airings load into the guide")
        IOSTest.settle(3)
        IOSTest.capture("d01-free-guide", in: self)
        IOSTest.element(app, "livetv.info").tap()
        assertPlays(app, "d02-free-playing")
        let up = IOSTest.element(app, "livetv.channelUp")
        if !up.isHittable { app.tap() }
        XCTAssertTrue(up.waitForExistence(timeout: 5), "the player offers Channel Up")
        up.tap()
        IOSTest.settle(15)
        IOSTest.capture("d03-free-channel-up", in: self)
        XCTAssertFalse(app.alerts.firstMatch.exists, "the next channel plays without an error")
    }

    func testAPlaylistTransportStreamPlaysThroughTheRelay() throws {
        let app = try launch()
        guard let address = ProcessInfo.processInfo.environment["CRUCIBLE_DEVICE_PLAYLIST"], let host = URL(string: address)?.host else {
            throw XCTSkip("Needs CRUCIBLE_DEVICE_PLAYLIST")
        }
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
        field.typeText(address)
        app.alerts.buttons["Add"].tap()
        let added = app.alerts.matching(NSPredicate(format: "label CONTAINS 'channels'")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 60), "the playlist is read and its channels counted")
        IOSTest.capture("d04-playlist-added", in: self)
        added.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        choose(app, source: host)
        XCTAssertTrue(IOSTest.wait(for: programs(app).firstMatch, "exists == true", timeout: 120), "the playlist's channels join the guide")
        IOSTest.settle(5)
        IOSTest.capture("d05-playlist-guide", in: self)
        IOSTest.element(app, "livetv.info").tap()
        assertPlays(app, "d06-transport-stream-playing")
        removePlaylist(app, host: host)
    }

    /// Leaves the phone as it was: starts the app again and removes the playlist the test added.
    private func removePlaylist(_ app: XCUIApplication, host: String) {
        app.terminate()
        let app = IOSTest.launch(fresh: false)
        openLiveTV(app)
        let actions = IOSTest.element(app, "livetv.actions")
        XCTAssertTrue(actions.waitForExistence(timeout: 20))
        actions.tap()
        app.buttons["Channel Playlists"].tap()
        let playlist = app.cells.matching(NSPredicate(format: "label CONTAINS %@", host)).firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 10))
        playlist.tap()
        let remove = app.cells.matching(NSPredicate(format: "label CONTAINS 'Remove Playlist'")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tap()
        app.alerts.buttons["Remove Playlist"].tap()
        XCTAssertTrue(IOSTest.wait(for: playlist, "exists == false", timeout: 10), "the playlist is removed")
    }
}
