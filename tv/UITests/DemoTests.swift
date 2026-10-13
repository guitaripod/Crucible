import XCTest

/// Drives the demo through the real focus engine, against the real in-app demo library. Every launch is a new install
/// (`CRUCIBLE_FRESH=1`) with the scripted free store (`CRUCIBLE_PRO=free`), so locks, the Crucible Pro row and the paywall are
/// all in play, and none of them may show while the demo runs.
///
/// The app is launched without `CRUCIBLE_MOCK`. While the in-app library is being built, `CRUCIBLE_DEMO_VIA_MOCK=1` points the demo
/// at the mock server instead (`CRUCIBLE_DEMO_URL`), which serves the same shapes.
@MainActor
final class DemoTests: TVTestCase {
    private static let searchQuery = "the"
    private static let stepIDs = ["play", "browse", "search", "statistics"]

    override func setUp() {
        continueAfterFailure = false
        TVTest.configureMock()
    }

    private func launch(fresh: Bool = true, extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CRUCIBLE_UITEST"] = "1"
        let environment = ProcessInfo.processInfo.environment
        for (key, value) in environment where key.hasPrefix("CRUCIBLE_") && key != "CRUCIBLE_MOCK" && key != "CRUCIBLE_DEMO_URL" {
            app.launchEnvironment[key] = value
        }
        app.launchEnvironment["CRUCIBLE_PRO"] = "free"
        if fresh { app.launchEnvironment["CRUCIBLE_FRESH"] = "1" }
        if environment["CRUCIBLE_DEMO_VIA_MOCK"] == "1", let mock = environment["CRUCIBLE_MOCK"] {
            app.launchEnvironment["CRUCIBLE_DEMO_URL"] = mock
        }
        app.launchEnvironment.merge(extraEnvironment) { _, new in new }
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        AppNavigation.element(app, identifier)
    }

    private func waitForWelcome(_ app: XCUIApplication) {
        XCTAssertTrue(element(app, "onboarding.signIn").waitForExistence(timeout: 30), "Welcome never appeared")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "onboarding.signIn"))
        TVTest.settle()
    }

    private func startDemo(_ app: XCUIApplication) {
        waitForWelcome(app)
        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "onboarding.demo"), "Down from Sign in should reach Try the demo")
        TVTest.remote.press(.select)
    }

    private func waitForIntro(_ app: XCUIApplication) {
        XCTAssertTrue(element(app, "demo.intro.start").waitForExistence(timeout: 90), "the intro never appeared")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "demo.intro.start"), "focus should rest on Start exploring")
        TVTest.settle(1.5)
    }

    private func waitForHome(_ app: XCUIApplication) {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60), "the main UI never appeared")
        XCTAssertTrue(AppNavigation.firstElement(app, prefix: AppNavigation.homeCardPrefix).waitForExistence(timeout: 60), "Home never showed a card")
        TVTest.settle(1.5)
    }

    private func enterDemo(_ app: XCUIApplication) {
        startDemo(app)
        waitForIntro(app)
        TVTest.remote.press(.select)
        waitForHome(app)
    }

    private func launchIntoHome() -> XCUIApplication {
        let app = launch()
        enterDemo(app)
        return app
    }

    private func openYou(_ app: XCUIApplication) {
        AppNavigation.selectTab("You", in: app)
        XCTAssertTrue(element(app, "you.demo").waitForExistence(timeout: 15), "the Demo library row is missing")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.demo"), "the Demo library row should lead the list")
        TVTest.settle()
    }

    private func openTour(_ app: XCUIApplication) {
        openYou(app)
        TVTest.remote.press(.select)
        XCTAssertTrue(element(app, "demo.step.play").waitForExistence(timeout: 15), "the tour never opened")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "demo.step.play"))
        TVTest.settle()
    }

    private static let tourOrder = ["demo.step.play", "demo.step.browse", "demo.step.search", "demo.step.statistics", "demo.connect", "demo.pro", "demo.leave"]

    /// Walks Up or Down the tour list to `identifier`, from wherever focus came back to.
    private func focusTourRow(_ app: XCUIApplication, _ identifier: String) {
        guard let target = Self.tourOrder.firstIndex(of: identifier) else { return XCTFail("unknown row \(identifier)") }
        for _ in 0..<10 {
            if element(app, identifier).hasFocus { return }
            guard let current = Self.tourOrder.firstIndex(where: { element(app, $0).hasFocus }) else {
                TVTest.remote.press(.down)
                TVTest.settle(0.4)
                continue
            }
            TVTest.remote.press(target > current ? .down : .up)
            TVTest.settle(0.4)
        }
        XCTAssertTrue(element(app, identifier).hasFocus, "focus never reached \(identifier)")
    }

    private func isDone(_ app: XCUIApplication, _ step: String) -> Bool {
        element(app, "demo.step.\(step)").value as? String == "Done"
    }

    private func waitForDone(_ app: XCUIApplication, _ step: String, timeout: TimeInterval = 30) {
        let row = element(app, "demo.step.\(step)")
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Done'"), object: row)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, "the \(step) step never got its check mark")
    }

    private func press(button title: String, in alert: XCUIElement) {
        let button = alert.buttons[title].firstMatch
        for _ in 0..<3 where !button.hasFocus {
            TVTest.remote.press(.right)
            TVTest.settle(0.5)
        }
        XCTAssertTrue(button.hasFocus, "focus never reached \(title)")
        TVTest.remote.press(.select)
    }

    /// Presses Menu until the player is gone: the tour screen is back, or the finale already covers it (which hides the screen
    /// below from the accessibility tree, so one more Menu would close the finale).
    private func leavePlayer(_ app: XCUIApplication, until screen: XCUIElement) {
        let finale = element(app, "demo.finale.keep")
        for _ in 0..<6 where !screen.exists && !finale.exists {
            TVTest.remote.press(.menu)
            TVTest.settle(2)
        }
        XCTAssertTrue(screen.waitForExistence(timeout: 15) || finale.exists, "Menu leaves the player")
    }

    private func playFromTour(_ app: XCUIApplication) {
        focusTourRow(app, "demo.step.play")
        TVTest.remote.press(.select)
        XCTAssertTrue(app.otherElements["player.view"].waitForExistence(timeout: 90), "the resume item never played")
        TVTest.settle(3)
    }

    private func doStatistics(_ app: XCUIApplication) {
        focusTourRow(app, "demo.step.statistics")
        TVTest.remote.press(.select)
        XCTAssertTrue(app.collectionViews["stats.collection"].waitForExistence(timeout: 90), "Statistics never appeared")
        TVTest.settle(2)
        TVTest.remote.press(.menu)
        XCTAssertTrue(element(app, "demo.step.statistics").waitForExistence(timeout: 15))
        TVTest.settle()
    }

    private func doBrowse(_ app: XCUIApplication) {
        focusTourRow(app, "demo.step.browse")
        TVTest.remote.press(.select)
        XCTAssertTrue(AppNavigation.firstElement(app, prefix: "tv.library.media.").waitForExistence(timeout: 60), "the library grid never appeared")
        TVTest.settle(2)
    }

    private func doSearch(_ app: XCUIApplication) {
        AppNavigation.selectTab("Search", in: app)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15), "the search keyboard never appeared")
        if app.tabBars.firstMatch.buttons["Search"].hasFocus {
            TVTest.remote.press(.down)
            TVTest.settle(1)
        }
        app.typeText(Self.searchQuery)
        TVTest.settle(3)
    }

    func testWelcomeOffersTheDemoBelowSignIn() {
        let app = launch()
        waitForWelcome(app)
        let demo = app.buttons["onboarding.demo"]
        XCTAssertTrue(demo.exists, "Welcome should offer Try the demo")
        XCTAssertEqual(demo.label, "Try the demo")
        XCTAssertEqual(element(app, "onboarding.demoCaption").label, "No server needed. Explore a fictional library.")
        TVTest.capture("01-welcome", in: self)

        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "onboarding.demo"))
        TVTest.settle()
        TVTest.capture("02-welcome-demo-focused", in: self)
    }

    func testEnteringShowsTheIntroThenAPopulatedHome() {
        let app = launch()
        startDemo(app)
        waitForIntro(app)
        TVTest.capture("03-intro", in: self)
        XCTAssertTrue(element(app, "demo.steps").exists, "the intro should list the things to try")

        TVTest.remote.press(.select)
        XCTAssertFalse(element(app, "demo.intro.start").waitForExistence(timeout: 3), "Start exploring should close the intro")
        waitForHome(app)
        TVTest.capture("04-home", in: self)
        XCTAssertFalse(element(app, "demo.finale.keep").exists, "the finale must not show before the tour is done")
    }

    func testMenuClosesTheIntroToo() {
        let app = launch()
        startDemo(app)
        waitForIntro(app)
        TVTest.remote.press(.menu)
        waitForHome(app)
        XCTAssertFalse(element(app, "demo.intro.start").exists)
    }

    func testYouListsTheDemoRowAndTheTourAtTheTop() {
        let app = launchIntoHome()
        openYou(app)
        TVTest.capture("05-you", in: self)
        XCTAssertTrue(element(app, "you.demo").label.hasPrefix("Demo library, "))
        XCTAssertFalse(element(app, "you.signOut").exists, "Sign Out is replaced by Leave the Demo")
        XCTAssertTrue(element(app, "you.leaveDemo").exists)
        XCTAssertFalse(element(app, "you.server").exists, "Server & Connection is hidden while the demo runs")

        TVTest.remote.press(.select)
        XCTAssertTrue(element(app, "demo.step.play").waitForExistence(timeout: 15))
        TVTest.settle(1.5)
        TVTest.capture("06-tour", in: self)
        for step in Self.stepIDs {
            XCTAssertTrue(element(app, "demo.step.\(step)").exists, "the \(step) step is missing")
        }
        for step in ["play", "search", "statistics"] {
            XCTAssertFalse(isDone(app, step), "\(step) cannot be done before anything was tried")
        }
        XCTAssertFalse(element(app, "demo.step.poster").exists, "the poster step is an iPhone feature")
        XCTAssertFalse(element(app, "demo.step.download").exists, "downloads are an iPhone feature")
        XCTAssertTrue(element(app, "demo.connect").exists)
        XCTAssertTrue(element(app, "demo.pro").exists)
        XCTAssertTrue(element(app, "demo.leave").exists)
    }

    func testPlayingATitleTicksThePlayStep() {
        let app = launchIntoHome()
        openTour(app)
        playFromTour(app)
        TVTest.capture("07-playing", in: self)
        leavePlayer(app, until: element(app, "demo.step.play"))
        waitForDone(app, "play")
        TVTest.settle()
        TVTest.capture("08-tour-play-done", in: self)
        XCTAssertFalse(element(app, "demo.finale.keep").waitForExistence(timeout: 4), "one step must not open the finale")
    }

    func testBrowsingTheLibraryAndStatisticsTickTheirSteps() {
        let app = launchIntoHome()
        openTour(app)
        doStatistics(app)
        waitForDone(app, "statistics")
        doBrowse(app)
        AppNavigation.selectTab("You", in: app)
        XCTAssertTrue(element(app, "demo.step.browse").waitForExistence(timeout: 15))
        waitForDone(app, "browse")
        XCTAssertEqual(element(app, "demo.step.play").value as? String, "Show me")
    }

    func testSearchResultsTickTheSearchStep() {
        let app = launchIntoHome()
        doSearch(app)
        TVTest.capture("09-search-results", in: self)
        openYou(app)
        TVTest.remote.press(.select)
        XCTAssertTrue(element(app, "demo.step.search").waitForExistence(timeout: 15))
        waitForDone(app, "search")
    }

    func testStatisticsHasEveryRangeUnlocked() {
        let app = launchIntoHome()
        openYou(app)
        YouNavigation.openRow(app, "you.statistics")
        XCTAssertTrue(app.collectionViews["stats.collection"].waitForExistence(timeout: 90))
        TVTest.settle(2)
        TVTest.capture("10-statistics", in: self)
        for range in ["week", "month", "year", "all"] {
            let chip = app.buttons["stats.range.\(range)"]
            XCTAssertTrue(chip.exists, "the \(range) chip is missing")
            XCTAssertFalse(chip.label.contains("locked"), "the \(range) chip is locked during the demo")
        }
        XCTAssertFalse(app.buttons["stats.libraries"].label.contains("locked"), "the Libraries filter is locked during the demo")

        for _ in 0..<4 where !app.buttons["stats.range.month"].hasFocus {
            TVTest.remote.press(.right)
            TVTest.settle(0.4)
        }
        XCTAssertTrue(app.buttons["stats.range.month"].hasFocus)
        TVTest.remote.press(.select)
        TVTest.settle(2)
        XCTAssertFalse(element(app, "paywall.buy").exists, "Month must not open the paywall during the demo")
        XCTAssertTrue(app.buttons["stats.range.month"].isSelected, "Month should be chosen")
    }

    func testCrucibleProRowStillShowsThePaywallDuringTheDemo() {
        let app = launchIntoHome()
        openYou(app)
        YouNavigation.openRow(app, "you.pro")
        XCTAssertTrue(element(app, "paywall.buy").waitForExistence(timeout: 30), "the Crucible Pro row must open the paywall in the demo")
        TVTest.settle(1.5)
        TVTest.capture("11-paywall", in: self)
        TVTest.remote.press(.menu)
        XCTAssertTrue(element(app, "you.pro").waitForExistence(timeout: 15))
    }

    func testFinishingTheTourShowsTheFinaleOnceAndNeverOverThePlayer() {
        let app = launchIntoHome()
        openTour(app)
        doStatistics(app)
        doBrowse(app)
        doSearch(app)
        AppNavigation.selectTab("You", in: app)
        XCTAssertTrue(element(app, "demo.step.play").waitForExistence(timeout: 15))
        playFromTour(app)

        let finale = element(app, "demo.finale.keep")
        XCTAssertFalse(finale.waitForExistence(timeout: 8), "the finale must wait while the player is up")
        TVTest.capture("12-player-no-finale", in: self)

        leavePlayer(app, until: element(app, "demo.step.play"))
        XCTAssertTrue(finale.waitForExistence(timeout: 20), "the finale never appeared after the player closed")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "demo.finale.connect"))
        TVTest.settle(1.5)
        TVTest.capture("13-finale", in: self)

        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "demo.finale.pro"))
        TVTest.settle()
        TVTest.capture("14-finale-pro-focused", in: self)
        TVTest.remote.press(.select)
        XCTAssertTrue(element(app, "paywall.buy").waitForExistence(timeout: 30), "See Crucible Pro opens the paywall")
        TVTest.settle(1.5)
        TVTest.remote.press(.menu)
        XCTAssertTrue(finale.waitForExistence(timeout: 15), "closing the paywall returns to the finale")

        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "demo.finale.keep"))
        TVTest.remote.press(.select)
        XCTAssertFalse(finale.waitForExistence(timeout: 3), "Keep exploring should close the finale")
        XCTAssertTrue(element(app, "demo.step.play").exists)

        playFromTour(app)
        leavePlayer(app, until: element(app, "demo.step.play"))
        XCTAssertFalse(finale.waitForExistence(timeout: 8), "the finale shows once")
    }

    func testMenuClosesTheFinale() {
        let app = launchIntoHome()
        openTour(app)
        doStatistics(app)
        doBrowse(app)
        doSearch(app)
        AppNavigation.selectTab("You", in: app)
        playFromTour(app)
        leavePlayer(app, until: element(app, "demo.step.play"))
        XCTAssertTrue(element(app, "demo.finale.keep").waitForExistence(timeout: 20))
        TVTest.remote.press(.menu)
        XCTAssertFalse(element(app, "demo.finale.keep").waitForExistence(timeout: 3), "Menu closes the finale like Keep exploring")
    }

    func testLeavingAsksFirstAndReturnsToWelcome() {
        let app = launchIntoHome()
        openYou(app)
        YouNavigation.moveFocus(app, to: "you.leaveDemo")
        TVTest.remote.press(.select)
        let alert = app.alerts["Leave the Demo?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        TVTest.settle()
        TVTest.capture("15-leave-confirmation", in: self)
        TVTest.remote.press(.menu)
        XCTAssertFalse(alert.waitForExistence(timeout: 3), "Menu cancels the confirmation")
        XCTAssertTrue(element(app, "you.leaveDemo").exists, "cancelling stays in the demo")

        TVTest.remote.press(.select)
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        press(button: "Leave the Demo", in: alert)
        waitForWelcome(app)
        XCTAssertTrue(app.buttons["onboarding.demo"].exists, "after leaving, Welcome offers the demo again")
        TVTest.capture("16-welcome-after-leaving", in: self)
    }

    func testTheTourCanLeaveTheDemoToo() {
        let app = launchIntoHome()
        openTour(app)
        focusTourRow(app, "demo.leave")
        TVTest.remote.press(.select)
        let alert = app.alerts["Leave the Demo?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        press(button: "Leave the Demo", in: alert)
        waitForWelcome(app)
    }

    func testConnectYourPlexServerLeavesTheDemoAfterAskingToo() {
        let app = launchIntoHome()
        openTour(app)
        focusTourRow(app, "demo.connect")
        TVTest.remote.press(.select)
        let alert = app.alerts["Connect your Plex server"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        TVTest.settle()
        TVTest.capture("17-connect-confirmation", in: self)
        press(button: "Connect", in: alert)
        waitForWelcome(app)
    }

    func testRelaunchingMidDemoResumesItWithoutTheIntro() {
        let app = launchIntoHome()
        openTour(app)
        doStatistics(app)
        waitForDone(app, "statistics")
        openYou(app)
        let progress = element(app, "you.demo").label
        XCTAssertTrue(progress.hasPrefix("Demo library, "))
        app.terminate()

        let relaunched = launch(fresh: false)
        XCTAssertTrue(relaunched.tabBars.firstMatch.waitForExistence(timeout: 90), "the demo should resume into the main UI, not Welcome")
        XCTAssertFalse(element(relaunched, "onboarding.signIn").exists)
        XCTAssertFalse(element(relaunched, "demo.intro.start").waitForExistence(timeout: 4), "the intro shows once per demo")
        TVTest.settle(2)
        openYou(relaunched)
        XCTAssertEqual(element(relaunched, "you.demo").label, progress, "the tour progress survives a relaunch")
        TVTest.capture("18-resumed", in: self)
    }

    func testLeavingForgetsTheDemoForGood() {
        let app = launchIntoHome()
        openYou(app)
        YouNavigation.moveFocus(app, to: "you.leaveDemo")
        TVTest.remote.press(.select)
        press(button: "Leave the Demo", in: app.alerts["Leave the Demo?"])
        waitForWelcome(app)
        app.terminate()

        let relaunched = launch(fresh: false)
        waitForWelcome(relaunched)
        XCTAssertFalse(relaunched.tabBars.firstMatch.exists, "a left demo must not come back")
    }
}
