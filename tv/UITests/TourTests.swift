import XCTest

/// The app as a whole: every tab shows its real screen, the launch gate offers a way out when the
/// server is unreachable, and `crucible://` links open the real Detail and player from anywhere.
@MainActor
final class TourTests: TVTestCase {
    private struct Tab {
        let title: String
        let marker: String
    }

    private static let tabs = [
        Tab(title: "Home", marker: AppNavigation.homeCardPrefix),
        Tab(title: "Movies", marker: "tv.chip.all"),
        Tab(title: "TV Shows", marker: "tv.chip.all"),
        Tab(title: "Documentaries", marker: "tv.chip.all"),
        Tab(title: "More", marker: "tv.more.library."),
        Tab(title: "Search", marker: ""),
        Tab(title: "You", marker: "you.history"),
    ]
    private static let deadServer = "http://127.0.0.1:1"

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        await MainActor.run { AppNavigation.setMockFlags("latency_ms=0") }
    }

    /// Points the unreachable-server scenario at the mock's plex.tv: a token plex.tv accepts and no
    /// other server to heal onto, so the launch gate is the plain "server unreachable" one.
    private static func configurePlexTV(_ mock: String, query: String) {
        guard let url = URL(string: "\(mock)/mock/plextv-config?\(query)") else { return }
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 10)
    }

    private func waitForMarker(_ tab: Tab, in app: XCUIApplication) -> Bool {
        if tab.title == "Search" {
            return app.searchFields.firstMatch.waitForExistence(timeout: 20)
        }
        if tab.marker.hasSuffix(".") {
            return AppNavigation.firstElement(app, prefix: tab.marker).waitForExistence(timeout: 30)
        }
        return AppNavigation.element(app, tab.marker).waitForExistence(timeout: 30)
    }

    func testEveryTabShowsItsRealScreen() {
        let app = AppNavigation.launchHome()
        let titles = app.tabBars.firstMatch.buttons.allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(titles.first, "Home", "tab bar: \(titles)")
        XCTAssertEqual(Set(titles), Set(Self.tabs.map(\.title)), "tab bar: \(titles)")

        for (index, tab) in Self.tabs.enumerated() {
            AppNavigation.selectTab(tab.title, in: app)
            XCTAssertTrue(waitForMarker(tab, in: app), "\(tab.title) never showed its screen")
            XCTAssertFalse(app.staticTexts["placeholder.title"].exists, "\(tab.title) still shows a placeholder")
            TVTest.settle(1.0)
            TVTest.capture(String(format: "%02d-%@", index + 1, tab.title.lowercased().replacingOccurrences(of: " ", with: "-")), in: self)
        }
    }

    func testUnreachableServerOffersTryAgainAndSwitchServer() {
        let mock = ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"] ?? ""
        Self.configurePlexTV(mock, query: "servers=none&reject_token=0")
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_MOCK": Self.deadServer, "CRUCIBLE_PLEXTV": mock])
        let retry = app.buttons["Try Again"]
        let switchServer = app.buttons["Switch Server"]
        XCTAssertTrue(retry.waitForExistence(timeout: 150))
        XCTAssertTrue(switchServer.exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertTrue(TVTest.waitForFocus(retry))
        TVTest.settle()
        TVTest.capture("01-failure-try-again-focused", in: self)

        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(switchServer))
        TVTest.settle()
        TVTest.capture("02-failure-switch-server-focused", in: self)

        TVTest.remote.press(.select)
        XCTAssertTrue(app.collectionViews["onboarding.servers"].waitForExistence(timeout: 45), "Switch Server must present the server list for the saved account")
        TVTest.settle()
        TVTest.capture("03-switch-server-presented", in: self)

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(app.buttons["Switch Server"]))

        TVTest.remote.press(.up)
        XCTAssertTrue(TVTest.waitForFocus(app.buttons["Try Again"]))
        TVTest.remote.press(.select)
        TVTest.settle(0.3)
        TVTest.capture("04-retrying", in: self)
        XCTAssertTrue(TVTest.waitForFocus(app.buttons["Try Again"], timeout: 90))
    }

    func testDeepLinksOpenTheRealDetailOnHomeAndTheRealPlayer() {
        AppNavigation.setMockProgress("1002", seconds: 10)
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_PLAYER_HOLD": "6"])
        AppNavigation.selectTab("Movies", in: app)
        XCTAssertTrue(AppNavigation.element(app, "tv.chip.all").waitForExistence(timeout: 30))

        AppNavigation.openFromOutside("crucible://item/4009?type=episode", in: self)
        XCTAssertTrue(AppNavigation.detailPrimary(app).waitForExistence(timeout: 30), "an item link must open the real Detail")
        TVTest.settle(1.5)
        XCTAssertFalse(app.staticTexts["placeholder.title"].exists)
        TVTest.capture("01-item-link-opened-detail-on-home", in: self)
        AppNavigation.expectHomeUnderDetail(app)

        AppNavigation.openFromOutside("crucible://item/1002", in: self)
        let deepField = NSPredicate(format: "label CONTAINS 'Deep Field'")
        let primary = AppNavigation.detailPrimary(app)
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: deepField, object: primary)], timeout: 30), .completed, "a link without a type resolves the item first, then opens its Detail: \(primary.label)")
        TVTest.settle(1.0)
        TVTest.capture("02-untyped-item-link-opened-detail", in: self)

        AppNavigation.openFromOutside("crucible://play/1002", in: self)
        let reachedPlayer = app.otherElements.matching(NSPredicate(format: "identifier IN {'player.preroll', 'player.view'}")).firstMatch
        XCTAssertTrue(reachedPlayer.waitForExistence(timeout: 60), "a play link must reach the player pre-roll or the player")
        TVTest.capture("03-play-link-reached-the-player", in: self)
        XCTAssertTrue(app.otherElements["player.view"].waitForExistence(timeout: 60), "the pre-roll must hand over to playback")
        TVTest.settle(2)
        TVTest.capture("04-playing", in: self)
        AppNavigation.leavePlayer(app)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
    }

    func testLinkThatLaunchesTheAppWaitsForTheMainUI() {
        let app = AppNavigation.launchHome()
        app.terminate()
        AppNavigation.setMockFlags("latency_ms=2500")

        AppNavigation.openFromOutside("crucible://item/4009?type=episode", in: self)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 90), "the launch gate must hand over to the main UI")
        XCTAssertTrue(AppNavigation.detailPrimary(app).waitForExistence(timeout: 60), "the link that launched the app must open its Detail once the main UI is up")
        TVTest.settle(1.5)
        TVTest.capture("01-launch-link-opened-detail", in: self)
        AppNavigation.expectHomeUnderDetail(app)
    }
}
