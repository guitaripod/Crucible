import XCTest

/// Drives Crucible Pro through the real focus engine with the scripted store (`CRUCIBLE_PRO*`): the locks on a free install's
/// Statistics, the paywall in every phase, every way a purchase or a restore can end, and the Pro screen. Without `CRUCIBLE_PRO`
/// the app is a source build: unlocked, with no locks and no Pro row.
@MainActor
final class ProTests: TVTestCase {
    private static let paywallTimeout: TimeInterval = 30

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchStatistics(_ store: [String: String] = [:]) -> XCUIApplication {
        var environment = ["CRUCIBLE_OPEN": "statistics", "CRUCIBLE_FRESH": "1", "CRUCIBLE_PRO": "free"]
        environment.merge(store) { _, new in new }
        let app = TVTest.launch(extraEnvironment: environment)
        XCTAssertTrue(app.collectionViews["stats.collection"].waitForExistence(timeout: 90), "the statistics page never appeared")
        TVTest.settle(2)
        return app
    }

    private func launchYou(_ store: [String: String] = [:]) -> XCUIApplication {
        var environment = ["CRUCIBLE_FRESH": "1", "CRUCIBLE_PRO": "free"]
        environment.merge(store) { _, new in new }
        let app = TVTest.launch(extraEnvironment: environment)
        YouNavigation.openYouTab(app)
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        AppNavigation.element(app, identifier)
    }

    private func chip(_ app: XCUIApplication, _ range: String) -> XCUIElement {
        app.buttons["stats.range.\(range)"]
    }

    /// The debug entry leaves focus on the tab bar; Down lands on a chip, and Left or Right walks to `range`. With `fromTabBar` off, focus is already on the chip row.
    private func focusChip(_ app: XCUIApplication, _ range: String, fromTabBar: Bool = true) {
        if fromTabBar { TVTest.remote.press(.down) }
        let order = ["week", "month", "year", "all"]
        for _ in 0..<4 {
            if chip(app, range).hasFocus { return }
            guard let target = order.firstIndex(of: range),
                  let current = order.firstIndex(where: { chip(app, $0).hasFocus }) else {
                TVTest.remote.press(.right)
                continue
            }
            TVTest.remote.press(target > current ? .right : .left)
            TVTest.settle(0.4)
        }
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "stats.range.\(range)", timeout: 5), "focus never reached the \(range) chip")
    }

    private func waitForPaywall(_ app: XCUIApplication) {
        XCTAssertTrue(element(app, "paywall.buy").waitForExistence(timeout: Self.paywallTimeout), "the paywall never showed its plans")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "paywall.buy"), "focus should rest on the buy button, not on \(AppNavigation.focusedIdentifier(app))")
        TVTest.settle(1)
    }

    private func openPaywallFromMonth(_ app: XCUIApplication) {
        focusChip(app, "month")
        TVTest.remote.press(.select)
        waitForPaywall(app)
    }

    private func waitForStatus(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let status = element(app, "paywall.status")
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: status)], timeout: timeout), .completed, "the status never said \(text): \(status.label)", file: file, line: line)
    }

    private func waitForStatusToClear(_ app: XCUIApplication, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let status = element(app, "paywall.status")
        let predicate = NSPredicate(format: "exists == false OR label == ''")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: status)], timeout: timeout), .completed, "the status never cleared: \(status.label)", file: file, line: line)
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 30, _ message: String) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, message)
    }

    private func expectNoLocks(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for range in ["week", "month", "year", "all"] {
            XCTAssertFalse(chip(app, range).label.contains("locked"), "the \(range) chip should not be locked", file: file, line: line)
        }
        XCTAssertFalse(app.buttons["stats.libraries"].label.contains("locked"), "the Libraries filter should not be locked", file: file, line: line)
    }

    func testFreeStatisticsShowsLocksAndMonthOpensThePaywall() {
        let app = launchStatistics()
        XCTAssertFalse(chip(app, "week").label.contains("locked"))
        for range in ["month", "year", "all"] {
            XCTAssertEqual(chip(app, range).label, "\(range == "all" ? "All" : range.capitalized), locked")
        }
        XCTAssertTrue(app.buttons["stats.libraries"].label.hasSuffix("locked"), app.buttons["stats.libraries"].label)
        XCTAssertTrue(chip(app, "week").isSelected, "a free install opens on the Week range")
        focusChip(app, "week")
        TVTest.capture("01-free-statistics-locks", in: self)

        TVTest.remote.press(.right)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "stats.range.month"))
        TVTest.remote.press(.select)
        waitForPaywall(app)
        TVTest.capture("02-paywall-from-month", in: self)
        XCTAssertTrue(element(app, "paywall.header").label.contains("Month, Year, All"), "the paywall should say why it opened: \(element(app, "paywall.header").label)")

        TVTest.remote.press(.menu)
        waitForGone(element(app, "paywall.buy"), "Menu should close the paywall")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "stats.range.month"), "focus must return to the chip that opened the paywall")
        XCTAssertTrue(chip(app, "week").isSelected, "closing the paywall must not change the range")
        XCTAssertEqual(chip(app, "month").label, "Month, locked")
        TVTest.capture("03-after-menu", in: self)
    }

    func testLibrariesFilterIsLockedAndOpensThePaywall() {
        let app = launchStatistics()
        focusChip(app, "week")
        for _ in 0..<4 { TVTest.remote.press(.right) }
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "stats.libraries"))
        TVTest.capture("01-libraries-locked", in: self)
        TVTest.remote.press(.select)
        waitForPaywall(app)
        TVTest.remote.press(.menu)
        waitForGone(element(app, "paywall.buy"), "Menu should close the paywall")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "stats.libraries"))
    }

    func testPaywallReadyStateWithTheFreeTrial() {
        let app = launchYou()
        XCTAssertEqual(YouNavigation.row(app, "you.pro").label, "Crucible Pro, Unlock full Statistics and Top Shelf")
        YouNavigation.moveFocus(app, to: "you.pro")
        TVTest.capture("00-you-list-free-row", in: self)
        YouNavigation.openRow(app, "you.pro")
        waitForPaywall(app)
        TVTest.capture("01-ready-lifetime-selected", in: self)

        XCTAssertEqual(app.buttons["paywall.buy"].label, "Unlock for $24.99")
        XCTAssertEqual(element(app, "paywall.offer.lifetime").value as? String, "Selected")
        XCTAssertTrue(element(app, "paywall.offer.annual").label.contains("14-day free trial, then $7.99 per year"), element(app, "paywall.offer.annual").label)
        XCTAssertFalse(element(app, "paywall.disclosure").exists, "the renewal terms belong to the annual plan")
        XCTAssertTrue(element(app, "paywall.legal").label.contains("https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"))
        XCTAssertTrue(element(app, "paywall.legal").label.contains("Privacy Policy"))
        XCTAssertTrue(element(app, "paywall.features").label.contains("Top Shelf"))
        XCTAssertFalse(element(app, "paywall.features").label.contains("downloads"), "downloads are iPhone only")

        TVTest.remote.press(.up)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "paywall.offer.annual"))
        TVTest.remote.press(.select)
        TVTest.settle(1)
        XCTAssertEqual(element(app, "paywall.offer.annual").value as? String, "Selected")
        XCTAssertEqual(app.buttons["paywall.buy"].label, "Start 14-day free trial")
        let disclosure = element(app, "paywall.disclosure")
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "the renewal terms must show while the annual plan is chosen")
        XCTAssertTrue(disclosure.label.contains("14-day free trial starts today"), disclosure.label)
        XCTAssertTrue(disclosure.label.contains("cancel at least 24 hours"), disclosure.label)
        TVTest.capture("02-annual-selected-with-terms", in: self)

        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "paywall.buy"))
        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "paywall.restore"))
        TVTest.capture("03-restore-focused", in: self)

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.pro"), "focus must return to the row that opened the paywall")
    }

    func testPaywallReadyStateWithoutTheFreeTrial() {
        let app = launchYou(["CRUCIBLE_PRO_TRIAL": "0"])
        YouNavigation.openRow(app, "you.pro")
        waitForPaywall(app)
        XCTAssertEqual(element(app, "paywall.offer.annual").label.contains("free trial"), false, element(app, "paywall.offer.annual").label)
        XCTAssertTrue(element(app, "paywall.offer.annual").label.contains("$7.99 per year"))

        TVTest.remote.press(.up)
        TVTest.remote.press(.select)
        TVTest.settle(1)
        XCTAssertEqual(app.buttons["paywall.buy"].label, "Subscribe for $7.99 a year")
        let disclosure = element(app, "paywall.disclosure")
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertFalse(disclosure.label.contains("free trial"), disclosure.label)
        XCTAssertTrue(disclosure.label.contains("charged $7.99 per year"), disclosure.label)
        TVTest.capture("01-annual-without-trial", in: self)
    }

    func testPurchaseSuccessUnlocksTheRangeAndRemovesEveryLock() {
        let app = launchStatistics(["CRUCIBLE_PRO_DELAY_MS": "2500"])
        openPaywallFromMonth(app)
        TVTest.remote.press(.select)
        waitForStatus(app, "Waiting for the App Store\u{2026}", timeout: 10)
        XCTAssertEqual(app.buttons["paywall.buy"].label, "Purchasing\u{2026}")
        XCTAssertTrue(app.buttons["paywall.buy"].hasFocus, "focus must stay on the button while the store works")
        TVTest.capture("01-purchasing", in: self)
        TVTest.remote.press(.select)
        TVTest.remote.press(.down)
        TVTest.settle(0.5)
        XCTAssertTrue(app.buttons["paywall.restore"].hasFocus || app.buttons["paywall.buy"].hasFocus)

        waitForGone(element(app, "paywall.buy"), "a successful purchase must close the paywall")
        XCTAssertTrue(app.collectionViews["stats.collection"].waitForExistence(timeout: 30))
        TVTest.settle(3)
        XCTAssertTrue(chip(app, "month").isSelected, "the range the user reached for must open after the purchase")
        expectNoLocks(app)
        TVTest.capture("02-unlocked-month", in: self)

        focusChip(app, "all", fromTabBar: false)
        TVTest.remote.press(.select)
        TVTest.settle(2)
        XCTAssertTrue(chip(app, "all").isSelected, "Pro chips must select without a paywall")
        XCTAssertFalse(element(app, "paywall.buy").exists)
    }

    func testCancellingThePurchaseReturnsToThePaywallQuietly() {
        let app = launchStatistics(["CRUCIBLE_PRO_STORE": "cancel", "CRUCIBLE_PRO_DELAY_MS": "2500"])
        openPaywallFromMonth(app)
        TVTest.remote.press(.select)
        waitForStatus(app, "Waiting for the App Store\u{2026}", timeout: 10)
        waitForStatusToClear(app)
        XCTAssertEqual(app.buttons["paywall.buy"].label, "Unlock for $24.99")
        XCTAssertTrue(app.buttons["paywall.buy"].hasFocus, "focus should still be on the buy button")
        TVTest.capture("01-after-cancel", in: self)
        TVTest.remote.press(.menu)
        waitForGone(element(app, "paywall.buy"), "Menu should close the paywall")
        XCTAssertEqual(chip(app, "month").label, "Month, locked")
    }

    func testPendingApprovalShowsTheNoticeAndStaysLocked() {
        let app = launchStatistics(["CRUCIBLE_PRO_STORE": "pending"])
        openPaywallFromMonth(app)
        TVTest.remote.press(.select)
        waitForStatus(app, "waiting for approval")
        XCTAssertTrue(app.buttons["paywall.buy"].hasFocus)
        TVTest.capture("01-pending", in: self)
        TVTest.remote.press(.menu)
        waitForGone(element(app, "paywall.buy"), "Menu should close the paywall")
        XCTAssertEqual(chip(app, "month").label, "Month, locked", "a purchase waiting for approval must not unlock anything")
    }

    func testRestoreFoundUnlocksAndContinuesToTheRange() {
        let app = launchStatistics(["CRUCIBLE_PRO_RESTORE": "found", "CRUCIBLE_PRO_DELAY_MS": "2500"])
        openPaywallFromMonth(app)
        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "paywall.restore"))
        TVTest.remote.press(.select)
        waitForStatus(app, "Restoring your purchases\u{2026}", timeout: 10)
        TVTest.capture("01-restoring", in: self)
        waitForGone(element(app, "paywall.buy"), "a restored purchase must close the paywall")
        TVTest.settle(3)
        XCTAssertTrue(chip(app, "month").isSelected)
        expectNoLocks(app)
    }

    func testRestoreWithNothingToRestoreShowsTheNotice() {
        let app = launchStatistics(["CRUCIBLE_PRO_RESTORE": "none"])
        openPaywallFromMonth(app)
        TVTest.remote.press(.down)
        TVTest.remote.press(.select)
        waitForStatus(app, "No Crucible Pro purchase was found")
        XCTAssertTrue(app.buttons["paywall.restore"].hasFocus, "focus must stay on Restore Purchases")
        XCTAssertEqual(app.buttons["paywall.restore"].label, "Restore Purchases")
        TVTest.capture("01-nothing-to-restore", in: self)
        XCTAssertTrue(element(app, "paywall.buy").exists, "the paywall stays open")
    }

    func testRestoreFailureShowsTheFailureNotice() {
        let app = launchStatistics(["CRUCIBLE_PRO_RESTORE": "fail"])
        openPaywallFromMonth(app)
        TVTest.remote.press(.down)
        TVTest.remote.press(.select)
        waitForStatus(app, "The App Store did not answer")
        TVTest.capture("01-restore-failed", in: self)
        XCTAssertTrue(app.buttons["paywall.restore"].hasFocus)
    }

    func testUnavailableStoreShowsTheMessageAndRetryHasFocus() {
        let app = launchStatistics(["CRUCIBLE_PRO_STORE": "offline"])
        focusChip(app, "month")
        TVTest.remote.press(.select)
        XCTAssertTrue(app.staticTexts["Crucible Pro Is Unavailable"].waitForExistence(timeout: Self.paywallTimeout))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "appear to be offline")).firstMatch.exists)
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.exists)
        XCTAssertTrue(TVTest.waitForFocus(retry), "Retry should have focus")
        TVTest.capture("01-unavailable", in: self)

        TVTest.remote.press(.select)
        XCTAssertTrue(app.staticTexts["Crucible Pro Is Unavailable"].waitForExistence(timeout: Self.paywallTimeout), "an offline store stays unavailable after Retry")
        XCTAssertTrue(TVTest.waitForFocus(app.buttons["Retry"]), "Retry should have focus again")

        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(app.buttons["Close"]))
        TVTest.remote.press(.select)
        waitForGone(app.buttons["Retry"], "Close should close the paywall")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "stats.range.month"))
    }

    func testAnEmptyOfferingExplainsItself() {
        let app = launchStatistics(["CRUCIBLE_PRO_STORE": "empty"])
        focusChip(app, "year")
        TVTest.remote.press(.select)
        XCTAssertTrue(app.staticTexts["Crucible Pro Is Unavailable"].waitForExistence(timeout: Self.paywallTimeout))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "not available in your region")).firstMatch.exists)
        TVTest.remote.press(.menu)
        waitForGone(app.buttons["Retry"], "Menu should close the unavailable paywall")
    }

    func testLoadingShowsASpinnerAndMenuStillCloses() {
        let app = launchStatistics(["CRUCIBLE_PRO_DELAY_MS": "6000"])
        focusChip(app, "month")
        TVTest.remote.press(.select)
        XCTAssertTrue(app.staticTexts["Loading Crucible Pro\u{2026}"].waitForExistence(timeout: 15))
        TVTest.capture("01-loading", in: self)
        TVTest.remote.press(.menu)
        waitForGone(app.staticTexts["Loading Crucible Pro\u{2026}"], "Menu must close the paywall while it loads")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "stats.range.month"))
        XCTAssertEqual(chip(app, "month").label, "Month, locked")
    }

    func testPaywallAndProScreenInTheLightAppearance() {
        let app = launchYou(["CRUCIBLE_STYLE": "light"])
        YouNavigation.openRow(app, "you.pro")
        waitForPaywall(app)
        TVTest.capture("01-light-ready", in: self)
        TVTest.remote.press(.up)
        TVTest.remote.press(.select)
        TVTest.settle(1)
        XCTAssertTrue(element(app, "paywall.disclosure").waitForExistence(timeout: 5))
        TVTest.capture("02-light-annual-selected", in: self)
        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        TVTest.remote.press(.select)
        waitForStatus(app, "No Crucible Pro purchase was found")
        TVTest.capture("03-light-notice", in: self)
    }

    func testPaywallReadsAsStopsForVoiceOver() {
        let app = launchStatistics(["CRUCIBLE_VOICEOVER": "1"])
        openPaywallFromMonth(app)
        var reached = Set<String>()
        let path: [XCUIRemote.Button] = [.up, .up, .left, .up, .up, .up, .down, .down, .down, .down]
        for button in path {
            reached.insert(AppNavigation.focusedIdentifier(app))
            TVTest.remote.press(button)
            TVTest.settle(0.5)
        }
        reached.insert(AppNavigation.focusedIdentifier(app))
        for identifier in ["paywall.offer.lifetime", "paywall.offer.annual", "paywall.legal", "paywall.features", "paywall.header"] {
            XCTAssertTrue(reached.contains(identifier), "VoiceOver focus never reached \(identifier): \(reached)")
        }
    }

    func testProUserSeesNoLocksAndTheRowShowsThePlan() {
        let app = launchStatistics(["CRUCIBLE_PRO": "lifetime"])
        expectNoLocks(app)
        focusChip(app, "year")
        XCTAssertTrue(chip(app, "year").isSelected, "a Pro install opens on Year")
        TVTest.capture("01-pro-statistics", in: self)
        TVTest.remote.press(.select)
        TVTest.remote.press(.right)
        TVTest.remote.press(.select)
        TVTest.settle(2)
        XCTAssertTrue(chip(app, "all").isSelected)
        XCTAssertFalse(element(app, "paywall.buy").exists, "Pro never meets the paywall")
    }

    func testProScreenShowsThePlanAndRestore() {
        let app = launchYou(["CRUCIBLE_PRO": "annual"])
        XCTAssertTrue(YouNavigation.row(app, "you.pro").label.hasPrefix("Crucible Pro, Annual \u{00B7} renews"), YouNavigation.row(app, "you.pro").label)
        YouNavigation.openRow(app, "you.pro")
        XCTAssertTrue(YouNavigation.row(app, "pro.restore").waitForExistence(timeout: 15))
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "pro.restore"))
        XCTAssertFalse(element(app, "paywall.buy").exists, "a Pro user's row opens the plan, not the paywall")
        XCTAssertTrue(element(app, "settings.context").label.hasPrefix("Crucible Pro. Annual"), element(app, "settings.context").label)
        XCTAssertEqual(element(app, "pro.manage").label, "To manage or cancel: Settings > Users & Accounts > your account > Subscriptions")
        XCTAssertTrue(element(app, "paywall.legal").label.contains("Privacy Policy"))
        XCTAssertTrue(YouNavigation.row(app, "pro.feature.fullStatistics").exists)
        XCTAssertTrue(YouNavigation.row(app, "pro.feature.topShelf").exists)
        TVTest.capture("01-pro-screen-annual", in: self)

        TVTest.remote.press(.select)
        XCTAssertTrue(app.alerts["Nothing to Restore"].waitForExistence(timeout: 15), "Restore on the Pro screen must say how it ended")
        TVTest.capture("02-restore-alert", in: self)
        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "pro.restore"))
    }

    func testLifetimeProScreenHasNoSubscriptionHelp() {
        let app = launchYou(["CRUCIBLE_PRO": "lifetime"])
        XCTAssertEqual(YouNavigation.row(app, "you.pro").label, "Crucible Pro, Lifetime")
        YouNavigation.openRow(app, "you.pro")
        XCTAssertTrue(YouNavigation.row(app, "pro.restore").waitForExistence(timeout: 15))
        XCTAssertFalse(element(app, "pro.manage").exists, "a lifetime purchase has no subscription to manage")
        TVTest.capture("01-pro-screen-lifetime", in: self)
    }

    func testSourceBuildHasNoLocksAndNoProRow() {
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_OPEN": "statistics", "CRUCIBLE_FRESH": "1"])
        XCTAssertTrue(app.collectionViews["stats.collection"].waitForExistence(timeout: 90))
        TVTest.settle(2)
        expectNoLocks(app)
        XCTAssertTrue(chip(app, "year").isSelected)
        TVTest.capture("01-source-statistics", in: self)

        let you = TVTest.launch(extraEnvironment: ["CRUCIBLE_FRESH": "1"])
        YouNavigation.openYouTab(you)
        XCTAssertFalse(YouNavigation.row(you, "you.pro").exists, "a build that cannot sell Pro has no Pro row")
        TVTest.capture("02-source-you", in: self)
    }
}
