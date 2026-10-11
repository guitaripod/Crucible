import XCTest

@MainActor
final class HomeTests: XCTestCase {
    private static let cardPrefix = "home.card."
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        MockHubs.set("ok")
    }

    override func tearDown() {
        MockHubs.set("ok")
    }

    private func launchHome(settleFor seconds: TimeInterval = 1.5) {
        app = TVTest.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60))
        XCTAssertTrue(firstCard("continueWatching").waitForExistence(timeout: 30), "Continue Watching should show")
        TVTest.settle(seconds)
    }

    private func cards(_ bucket: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "\(Self.cardPrefix)\(bucket)."))
    }

    private func firstCard(_ bucket: String) -> XCUIElement {
        cards(bucket).element(boundBy: 0)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var focusedIdentifier: String {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch.identifier
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1, settle: TimeInterval = 0.6) {
        for _ in 0..<times {
            TVTest.remote.press(button)
            TVTest.settle(settle)
        }
    }

    private func focusFirstContinueWatching() {
        if !firstCard("continueWatching").hasFocus {
            press(.down)
        }
        XCTAssertTrue(firstCard("continueWatching").hasFocus, "first Continue Watching card should hold focus, focus is on \(focusedIdentifier)")
    }

    private func moveDown(until identifierPrefix: String, maxPresses: Int = 8) {
        for _ in 0..<maxPresses where !focusedIdentifier.hasPrefix(identifierPrefix) {
            press(.down)
        }
        XCTAssertTrue(focusedIdentifier.hasPrefix(identifierPrefix), "expected focus on \(identifierPrefix), got \(focusedIdentifier)")
    }

    private func dismissAlert() {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        TVTest.remote.press(.select)
        TVTest.settle(0.8)
        XCTAssertFalse(alert.exists)
    }

    func testLoadedHomeFollowsFocusAndScrolls() {
        launchHome()
        TVTest.capture("01-loaded-initial", in: self)

        focusFirstContinueWatching()
        XCTAssertTrue(app.staticTexts["CONTINUE WATCHING"].exists, "hero eyebrow for Continue Watching")
        TVTest.settle(1.0)
        TVTest.capture("02-focus-first-continue-watching", in: self)

        press(.right)
        TVTest.settle(1.0)
        TVTest.capture("03-focus-second-continue-watching", in: self)

        press(.down)
        XCTAssertTrue(focusedIdentifier.hasPrefix(Self.cardPrefix + "upNext."), "focus should be on Up Next, got \(focusedIdentifier)")
        TVTest.settle(1.0)
        TVTest.capture("04-focus-up-next", in: self)

        moveDown(until: Self.cardPrefix + "recentlyAdded.")
        TVTest.settle(1.2)
        TVTest.capture("05-focus-recently-added-hero-updated", in: self)

        press(.right, times: 3)
        TVTest.settle(1.0)
        TVTest.capture("06-recently-added-scrolled-right", in: self)

        press(.up)
        XCTAssertTrue(
            focusedIdentifier.hasPrefix(Self.cardPrefix + "upNext.") || focusedIdentifier == "home.week",
            "Up from Recently Added lands on the row above, got \(focusedIdentifier)"
        )
        press(.down)
        if focusedIdentifier == "tv.sectionHeader.seeAll" { press(.down) }
        XCTAssertTrue(focusedIdentifier.hasPrefix(Self.cardPrefix + "recentlyAdded."), "Down returns to Recently Added, got \(focusedIdentifier)")
        press(.left, times: 3)
        press(.up, times: 2)
        press(.up, times: 2)
        TVTest.capture("07-back-up-near-top", in: self)
    }

    func testSelectPlaysOrOpensDetailPerRail() {
        launchHome()
        focusFirstContinueWatching()

        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "Select on Continue Watching plays")
        TVTest.capture("08-select-continue-watching-plays", in: self)
        dismissAlert()
        XCTAssertTrue(firstCard("continueWatching").hasFocus, "focus returns to the card after the player closes")

        TVTest.remote.press(.playPause)
        TVTest.settle(1.0)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "Play/Pause plays the focused card")
        dismissAlert()

        press(.right)
        press(.down)
        XCTAssertTrue(focusedIdentifier.hasPrefix(Self.cardPrefix + "upNext."), "got \(focusedIdentifier)")
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        XCTAssertTrue(
            app.alerts.firstMatch.exists || app.staticTexts["placeholder.title"].exists,
            "Select on Up Next plays a started item and opens detail otherwise"
        )
        TVTest.capture("09-select-up-next", in: self)
    }

    func testRecentlyAddedSelectOpensDetail() {
        launchHome()
        focusFirstContinueWatching()
        moveDown(until: Self.cardPrefix + "recentlyAdded.")
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        let title = app.staticTexts["placeholder.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Recently Added opens the detail screen")
        XCTAssertTrue(title.label.hasPrefix("Detail") || title.label.hasPrefix("Show"), "got \(title.label)")
        TVTest.capture("10-recently-added-opens-detail", in: self)
    }

    func testLongPressMenuOffersCardActions() {
        launchHome()
        focusFirstContinueWatching()
        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1.2)
        XCTAssertTrue(element("Resume").waitForExistence(timeout: 5), "Resume is offered for a started item")
        XCTAssertTrue(element("Play from Beginning").exists)
        XCTAssertTrue(element("View Details").exists)
        XCTAssertTrue(element("Mark Watched").exists)
        TVTest.capture("11-long-press-menu-continue-watching", in: self)

        TVTest.remote.press(.menu)
        TVTest.settle(1.0)
        XCTAssertFalse(element("Resume").exists)
        XCTAssertTrue(firstCard("continueWatching").hasFocus, "focus returns to the card the menu came from")
    }

    func testSeeAllOpensGridAndBackRestoresFocus() {
        launchHome()
        focusFirstContinueWatching()
        press(.down)
        let seeAll = element("tv.sectionHeader.seeAll")
        XCTAssertEqual(focusedIdentifier, "tv.sectionHeader.seeAll", "Down from the first card reaches Up Next's See All")
        TVTest.capture("12-see-all-focused", in: self)

        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        let grid = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.seeAll.")).firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 5), "See All opens the grid")
        TVTest.capture("13-see-all-grid", in: self)
        press(.down)
        TVTest.capture("14-see-all-grid-second-row", in: self)

        TVTest.remote.press(.menu)
        TVTest.settle(1.2)
        XCTAssertTrue(firstCard("continueWatching").waitForExistence(timeout: 5))
        XCTAssertTrue(seeAll.hasFocus || focusedIdentifier.hasPrefix(Self.cardPrefix), "Back returns to Home with focus on a Home control, got \(focusedIdentifier)")
        TVTest.capture("15-back-from-see-all", in: self)
    }

    func testRecentlyAddedSeeAllShowsPosterGrid() {
        launchHome()
        focusFirstContinueWatching()
        press(.down, times: 2)
        moveDown(until: "home.week", maxPresses: 3)
        press(.down)
        XCTAssertEqual(focusedIdentifier, "tv.sectionHeader.seeAll", "See All above Recently Added has focus")
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.seeAll.")).firstMatch.waitForExistence(timeout: 5))
        TVTest.capture("16-see-all-recently-added-grid", in: self)
    }

    func testWeekTileOpensStatistics() {
        launchHome()
        TVTest.settle(12)
        focusFirstContinueWatching()
        moveDown(until: "home.week", maxPresses: 6)
        TVTest.settle(1.0)
        TVTest.capture("17-this-week-tile-focused", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        XCTAssertEqual(app.staticTexts["placeholder.title"].label, "Statistics")
    }

    func testSurpriseTileOffersKindsAndOpensAPick() {
        launchHome()
        focusFirstContinueWatching()
        moveDown(until: Self.cardPrefix + "recentlyAdded.")
        for _ in 0..<40 where focusedIdentifier != "home.surprise" {
            TVTest.remote.press(.right)
            TVTest.settle(0.25)
        }
        TVTest.settle(0.8)
        XCTAssertEqual(focusedIdentifier, "home.surprise", "the Surprise Me tile ends Recently Added")
        TVTest.capture("18-surprise-tile-focused", in: self)

        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        TVTest.capture("18b-after-select-on-surprise", in: self)
        let menu = app.alerts.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(menu.buttons["Any"].exists)
        XCTAssertTrue(menu.buttons["Movie"].exists)
        XCTAssertTrue(menu.buttons["Show"].exists)
        TVTest.capture("19-surprise-menu", in: self)

        TVTest.remote.press(.select)
        let title = app.staticTexts["placeholder.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "a pick opens a detail screen")
        TVTest.capture("20-surprise-opened-pick", in: self)
    }

    func testEmptyHomeThenSlowRefreshShowsSkeletonThenContent() {
        MockHubs.set("empty")
        app = TVTest.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60))
        let refresh = app.buttons["Refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 20), "empty state offers Refresh")
        XCTAssertTrue(app.staticTexts["Nothing Here Yet"].exists)
        press(.down)
        XCTAssertTrue(refresh.hasFocus, "Down from the tab bar focuses Refresh")
        TVTest.settle(1.0)
        TVTest.capture("21-empty-home", in: self)

        MockHubs.set("slow")
        TVTest.remote.press(.select)
        TVTest.settle(1.2)
        TVTest.capture("22-loading-skeleton", in: self)
        XCTAssertTrue(firstCard("continueWatching").waitForExistence(timeout: 20), "content replaces the skeleton")
        TVTest.settle(1.5)
        TVTest.capture("23-recovered-content", in: self)
    }

    func testErrorStateOffersRetryAndRecovers() {
        MockHubs.set("empty")
        app = TVTest.launch()
        XCTAssertTrue(app.buttons["Refresh"].waitForExistence(timeout: 60))
        press(.down)
        MockHubs.set("error")
        TVTest.remote.press(.select)
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20), "an empty Home with a failing server shows the error")
        XCTAssertTrue(app.staticTexts["Couldn't Reach Server"].exists)
        TVTest.settle(1.0)
        TVTest.capture("24-error-state", in: self)

        MockHubs.set("ok")
        press(.down)
        XCTAssertTrue(retry.hasFocus, "Down from the tab bar focuses Retry")
        TVTest.remote.press(.select)
        XCTAssertTrue(firstCard("continueWatching").waitForExistence(timeout: 20), "Retry recovers")
        TVTest.settle(1.5)
        TVTest.capture("25-recovered-after-retry", in: self)
    }

    func testRefreshFailureKeepsContentOnScreen() {
        launchHome()
        MockHubs.set("error")
        press(.up)
        press(.right)
        press(.select)
        TVTest.settle(1.5)
        press(.left)
        press(.select)
        TVTest.settle(3.0)
        XCTAssertFalse(app.staticTexts["Couldn't Reach Server"].exists, "cached content stays, no error screen")
        XCTAssertTrue(firstCard("continueWatching").exists, "Continue Watching is still there")
        TVTest.capture("26-content-kept-after-failed-refresh", in: self)
    }
}

enum MockHubs {
    static func set(_ mode: String) {
        guard let base = ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"],
              let url = URL(string: "\(base)/mock/hubs?mode=\(mode)") else { return }
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 10)
    }
}
