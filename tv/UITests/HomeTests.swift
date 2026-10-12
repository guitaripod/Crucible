import XCTest

@MainActor
final class HomeTests: TVTestCase {
    private static let cardPrefix = "home.card."
    private static let seeAll = "tv.sectionHeader.seeAll"
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        MockControl.call("/mock/flags?latency_ms=0")
    }

    private func launchHome(mock: [String: String] = [:], extraEnvironment: [String: String] = [:]) {
        app = TVTest.launch(mock: mock, extraEnvironment: extraEnvironment)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60))
        XCTAssertTrue(firstCard("continueWatching").waitForExistence(timeout: 30), "Continue Watching should show")
        TVTest.settle(1.5)
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

    private func detailElement() -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'detail.'")).firstMatch
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

    private var tabBarHasFocus: Bool {
        app.tabBars.firstMatch.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists
    }

    private func selectTab(_ title: String) {
        for _ in 0..<14 where !tabBarHasFocus {
            press(.up, settle: 0.3)
        }
        XCTAssertTrue(tabBarHasFocus, "the tab bar should take focus")
        let titles = app.tabBars.firstMatch.buttons.allElementsBoundByIndex.map(\.label)
        guard let target = titles.firstIndex(of: title),
              let current = app.tabBars.firstMatch.buttons.allElementsBoundByIndex.firstIndex(where: { $0.hasFocus }) else {
            return XCTFail("tab \(title) not found in \(titles)")
        }
        for _ in 0..<abs(target - current) {
            press(target > current ? .right : .left, settle: 0.3)
        }
        TVTest.remote.press(.select)
        TVTest.settle(1.5)
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
        XCTAssertTrue(app.staticTexts["CONTINUE WATCHING"].exists || app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Continue Watching'")).firstMatch.exists, "hero for Continue Watching")
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
        TVTest.capture("05-focus-recently-added", in: self)

        press(.right, times: 3)
        TVTest.settle(1.0)
        TVTest.capture("06-recently-added-scrolled-right", in: self)

        press(.up)
        XCTAssertTrue(
            focusedIdentifier.hasPrefix(Self.cardPrefix + "upNext.") || focusedIdentifier == "home.week" || focusedIdentifier == Self.seeAll,
            "Up from Recently Added lands on the row above, got \(focusedIdentifier)"
        )
        press(.down)
        if focusedIdentifier == Self.seeAll || focusedIdentifier == "home.week" { press(.down) }
        XCTAssertTrue(focusedIdentifier.hasPrefix(Self.cardPrefix + "recentlyAdded."), "Down returns to Recently Added, got \(focusedIdentifier)")
        TVTest.capture("07-back-in-recently-added", in: self)
    }

    func testTheHeroComesBackWhenFocusClimbsToTheFirstRail() {
        launchHome()
        focusFirstContinueWatching()
        TVTest.settle(1.0)
        let header = app.staticTexts["Continue Watching"]
        XCTAssertTrue(header.exists)
        let restingTop = header.frame.minY

        moveDown(until: Self.cardPrefix + "recentlyAdded.")
        TVTest.settle(1.0)
        TVTest.capture("29-scrolled-down-to-recently-added", in: self)

        for _ in 0..<8 where !focusedIdentifier.hasPrefix(Self.cardPrefix + "continueWatching.") {
            press(.up)
        }
        XCTAssertTrue(focusedIdentifier.hasPrefix(Self.cardPrefix + "continueWatching."), "focus should climb back to Continue Watching, got \(focusedIdentifier)")
        TVTest.settle(1.2)
        TVTest.capture("30-back-on-the-first-rail", in: self)
        XCTAssertEqual(header.frame.minY, restingTop, accuracy: 2, "with focus on the first rail the hero is fully back in view")

        press(.up)
        XCTAssertTrue(tabBarHasFocus, "one more Up reaches the tab bar")
        TVTest.settle(1.0)
        TVTest.capture("31-tab-bar-over-the-hero", in: self)
        XCTAssertEqual(header.frame.minY, restingTop, accuracy: 2, "the hero stays in view under the tab bar")
    }

    func testTheHeroComesBackWhenUpNextIsTheFirstRail() {
        app = TVTest.launch(mock: ["MOCK_HOME_NO_CONTINUE": "1"])
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60))
        XCTAssertTrue(firstCard("upNext").waitForExistence(timeout: 30), "Up Next should show")
        XCTAssertFalse(firstCard("continueWatching").exists, "the mock leaves Continue Watching empty")
        TVTest.settle(1.5)
        if !focusedIdentifier.hasPrefix(Self.cardPrefix + "upNext.") { press(.down) }
        XCTAssertTrue(focusedIdentifier.hasPrefix(Self.cardPrefix + "upNext."), "focus should start on Up Next, got \(focusedIdentifier)")
        let header = app.staticTexts["Up Next"]
        XCTAssertTrue(header.exists)
        let restingTop = header.frame.minY

        moveDown(until: Self.cardPrefix + "recentlyAdded.")
        TVTest.settle(1.0)
        for _ in 0..<8 where !focusedIdentifier.hasPrefix(Self.cardPrefix + "upNext.") {
            press(.up)
        }
        XCTAssertTrue(focusedIdentifier.hasPrefix(Self.cardPrefix + "upNext."), "focus should climb back to Up Next, got \(focusedIdentifier)")
        TVTest.settle(1.2)
        TVTest.capture("32-up-next-first-rail-hero-back", in: self)
        XCTAssertEqual(header.frame.minY, restingTop, accuracy: 2, "with focus on the first rail, whichever it is, the hero is fully back in view")
    }

    func testSelectPlaysOrOpensDetailPerRailAndBackRestoresFocus() {
        launchHome(extraEnvironment: ["CRUCIBLE_PLAYER_HOLD": "20"])
        focusFirstContinueWatching()

        TVTest.remote.press(.select)
        XCTAssertTrue(app.otherElements["player.preroll"].waitForExistence(timeout: 30), "Select on Continue Watching starts playback")
        TVTest.capture("08-select-continue-watching-plays", in: self)
        TVTest.remote.press(.menu)
        XCTAssertTrue(firstCard("continueWatching").waitForExistence(timeout: 20))
        TVTest.settle(1.5)
        XCTAssertTrue(firstCard("continueWatching").hasFocus, "focus returns to the card after the player closes, got \(focusedIdentifier)")

        TVTest.remote.press(.playPause)
        XCTAssertTrue(app.otherElements["player.preroll"].waitForExistence(timeout: 30), "Play/Pause plays the focused card")
        TVTest.remote.press(.menu)
        XCTAssertTrue(firstCard("continueWatching").waitForExistence(timeout: 20))
        TVTest.settle(1.5)

        press(.right)
        press(.down)
        XCTAssertTrue(focusedIdentifier.hasPrefix(Self.cardPrefix + "upNext."), "got \(focusedIdentifier)")
        let upNext = focusedIdentifier
        TVTest.remote.press(.select)
        XCTAssertTrue(detailElement().waitForExistence(timeout: 20), "Select on an unstarted Up Next card opens its detail")
        TVTest.settle(1.0)
        TVTest.capture("09-select-up-next-opens-detail", in: self)
        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: upNext, timeout: 15), "Back restores focus to \(upNext), got \(focusedIdentifier)")
    }

    func testRecentlyAddedSelectOpensDetailAndBackRestoresFocus() {
        launchHome()
        focusFirstContinueWatching()
        moveDown(until: Self.cardPrefix + "recentlyAdded.")
        press(.right)
        let poster = focusedIdentifier
        TVTest.remote.press(.select)
        XCTAssertTrue(detailElement().waitForExistence(timeout: 20), "Recently Added opens the detail screen")
        TVTest.settle(1.0)
        TVTest.capture("10-recently-added-opens-detail", in: self)
        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: poster, timeout: 15), "Back restores focus to \(poster), got \(focusedIdentifier)")
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

    func testSeeAllOpensGridAndMenuPopsBackToTheButton() {
        launchHome()
        focusFirstContinueWatching()
        press(.down)
        XCTAssertEqual(focusedIdentifier, Self.seeAll, "Down from the first card reaches Up Next's See All")
        TVTest.capture("12-see-all-focused", in: self)

        TVTest.remote.press(.select)
        TVTest.settle(1.5)
        let grid = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.seeAll.")).firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 5), "See All opens the grid")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Up Next'")).firstMatch.exists, "the screen title names the rail")
        TVTest.capture("13-see-all-grid", in: self)
        press(.down)
        TVTest.capture("14-see-all-grid-second-row", in: self)

        TVTest.remote.press(.menu)
        XCTAssertTrue(firstCard("continueWatching").waitForExistence(timeout: 5), "Menu pops See All")
        TVTest.settle(1.2)
        XCTAssertEqual(focusedIdentifier, Self.seeAll, "Back returns focus to the See All button")
        TVTest.capture("15-back-from-see-all", in: self)
    }

    func testRecentlyAddedSeeAllShowsPosterGrid() {
        launchHome()
        focusFirstContinueWatching()
        press(.down, times: 2)
        moveDown(until: "home.week", maxPresses: 3)
        press(.down)
        XCTAssertEqual(focusedIdentifier, Self.seeAll, "See All above Recently Added has focus")
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
        XCTAssertTrue(element("stats.collection").waitForExistence(timeout: 20), "the tile opens Statistics")
        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "home.week", timeout: 15), "Back restores focus to the tile")
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
        let menu = app.alerts.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(menu.buttons["Any"].exists)
        XCTAssertTrue(menu.buttons["Movie"].exists)
        XCTAssertTrue(menu.buttons["Show"].exists)
        TVTest.capture("19-surprise-menu", in: self)

        TVTest.remote.press(.menu)
        TVTest.settle(1.0)
        XCTAssertFalse(menu.exists, "Menu dismisses the Surprise Me menu")
        XCTAssertEqual(focusedIdentifier, "home.surprise")

        TVTest.remote.press(.select)
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        TVTest.remote.press(.select)
        XCTAssertTrue(detailElement().waitForExistence(timeout: 20), "a pick opens a detail screen")
        TVTest.capture("20-surprise-opened-pick", in: self)
    }

    func testASlowSurprisePickDoesNotPushAfterLeavingHome() {
        launchHome()
        focusFirstContinueWatching()
        moveDown(until: Self.cardPrefix + "recentlyAdded.")
        for _ in 0..<40 where focusedIdentifier != "home.surprise" {
            TVTest.remote.press(.right)
            TVTest.settle(0.25)
        }
        TVTest.remote.press(.select)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        MockControl.call("/mock/flags?latency_ms=4000")
        TVTest.remote.press(.select)
        TVTest.settle(0.6)
        selectTab("Movies")
        TVTest.settle(8)
        MockControl.call("/mock/flags?latency_ms=0")
        selectTab("Home")
        TVTest.settle(3)
        TVTest.capture("21-home-after-abandoned-surprise", in: self)
        XCTAssertFalse(detailElement().exists, "a pick that finished after Home was left must not push onto its hidden stack")
        XCTAssertTrue(firstCard("continueWatching").waitForExistence(timeout: 10))
        TVTest.capture("21-home-after-abandoned-surprise", in: self)
    }

    func testEmptyHomeThenSlowRefreshShowsSkeletonThenContentWithFocus() {
        launchHomeEmpty()
        let refresh = app.buttons["Refresh"]
        XCTAssertTrue(app.staticTexts["Nothing Here Yet"].exists)
        TVTest.capture("21-empty-before-focus", in: self)
        if !refresh.hasFocus { press(.down) }
        XCTAssertTrue(refresh.hasFocus, "Refresh should hold focus, got \(focusedIdentifier) tabBarHasFocus=\(tabBarHasFocus)")
        TVTest.settle(1.0)
        TVTest.capture("22-empty-home", in: self)

        MockHubs.set("slow")
        TVTest.remote.press(.select)
        TVTest.settle(1.2)
        TVTest.capture("23-loading-skeleton", in: self)
        XCTAssertTrue(firstCard("continueWatching").waitForExistence(timeout: 20), "content replaces the skeleton")
        TVTest.settle(1.5)
        TVTest.capture("24-recovered-content-focused", in: self)
        XCTAssertTrue(firstCard("continueWatching").hasFocus, "focus lands on the first card without another press, got \(focusedIdentifier)")
    }

    func testErrorStateOffersRetryAndRecoversWithFocus() {
        launchHomeEmpty()
        if !app.buttons["Refresh"].hasFocus { press(.down) }
        MockHubs.set("error")
        TVTest.remote.press(.select)
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20), "an empty Home with a failing server shows the error")
        XCTAssertTrue(app.staticTexts["Couldn't Reach Server"].exists)
        TVTest.settle(1.0)
        XCTAssertTrue(retry.hasFocus, "focus follows the Refresh press onto Retry, got \(focusedIdentifier)")
        TVTest.capture("25-error-state", in: self)

        MockHubs.set("ok")
        TVTest.remote.press(.select)
        XCTAssertTrue(firstCard("continueWatching").waitForExistence(timeout: 20), "Retry recovers")
        TVTest.settle(1.5)
        TVTest.capture("26-recovered-after-retry", in: self)
        XCTAssertTrue(firstCard("continueWatching").hasFocus, "focus lands on the first card, got \(focusedIdentifier)")
    }

    func testRefreshFailureKeepsContentOnScreen() {
        launchHome()
        MockHubs.set("error")
        selectTab("Movies")
        selectTab("Home")
        TVTest.settle(3.0)
        TVTest.capture("27-content-kept-after-failed-refresh", in: self)
        XCTAssertFalse(app.staticTexts["Couldn't Reach Server"].exists, "cached content stays, no error screen")
        XCTAssertTrue(firstCard("continueWatching").exists, "Continue Watching is still there")
    }

    func testALongTitleAndSynopsisFitTheHeroBlock() {
        launchHome(mock: ["MOCK_HOME_LONG_HERO": "1"])
        focusFirstContinueWatching()
        TVTest.settle(1.2)
        TVTest.capture("28-long-hero", in: self)
        let hero = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'harbour lights'")).firstMatch
        XCTAssertTrue(hero.exists, "the hero reads as one element with the long title")
        let header = app.staticTexts["Continue Watching"]
        XCTAssertTrue(header.exists)
        XCTAssertLessThanOrEqual(hero.frame.maxY, header.frame.minY + 1, "the hero text must not reach the Continue Watching header")
        XCTAssertGreaterThanOrEqual(hero.frame.minY, 100, "the hero text must stay below the tab bar")
        XCTAssertTrue(hero.label.contains("Extraordinarily"), "VoiceOver reads the title together with the synopsis")
    }

    private func launchHomeEmpty() {
        app = TVTest.launch(mock: ["MOCK_HUBS_MODE": "empty"])
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["Refresh"].waitForExistence(timeout: 30), "an empty Home offers Refresh")
        TVTest.settle(1.0)
    }
}

enum MockHubs {
    static func set(_ mode: String) {
        MockControl.call("/mock/hubs?mode=\(mode)")
    }
}

enum MockControl {
    static func call(_ path: String) {
        guard let base = ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"], let url = URL(string: base + path) else { return }
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 10)
    }
}
