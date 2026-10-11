import XCTest

@MainActor
final class SettingsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        Self.setMockLatency(0)
    }

    private nonisolated static func setMockLatency(_ milliseconds: Int) {
        guard let base = ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"],
              let url = URL(string: base + "/mock/flags?latency_ms=\(milliseconds)") else { return }
        TVTest.fetch(url)
    }

    private func restoreDefaultLibraries(_ app: XCUIApplication) {
        guard YouNavigation.row(app, "libraries.reset").exists else { return }
        YouNavigation.openRow(app, "libraries.reset")
        TVTest.remote.press(.up)
        XCTAssertFalse(YouNavigation.row(app, "libraries.reset").exists)
        YouNavigation.moveFocusUp(app, to: "library.1")
        TVTest.settle()
    }

    private func value(of element: XCUIElement) -> String {
        (element.value as? String) ?? ""
    }

    func testPlaybackSelectionListAndToggle() {
        let app = TVTest.launch()
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.playback")
        let quality = YouNavigation.row(app, "playback.streamingQuality")
        XCTAssertTrue(quality.waitForExistence(timeout: 15))
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "playback.streamingQuality"))
        TVTest.settle()
        TVTest.capture("01-playback", in: self)

        TVTest.remote.press(.select)
        XCTAssertTrue(YouNavigation.row(app, "choice.8000").waitForExistence(timeout: 10))
        TVTest.settle()
        TVTest.capture("02-streaming-quality-list", in: self)

        YouNavigation.moveFocus(app, to: "choice.8000")
        TVTest.remote.press(.select)
        TVTest.settle()
        TVTest.capture("03-medium-selected", in: self)

        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "playback.streamingQuality"))
        XCTAssertEqual(value(of: YouNavigation.row(app, "playback.streamingQuality")), "Medium · 8 Mbps")

        YouNavigation.moveFocus(app, to: "playback.skipIntro")
        TVTest.capture("04-skip-intro-focused-with-explanation", in: self)

        YouNavigation.moveFocus(app, to: "playback.autoplayNextEpisode")
        let before = value(of: YouNavigation.row(app, "playback.autoplayNextEpisode"))
        TVTest.remote.press(.select)
        TVTest.settle(0.5)
        let after = value(of: YouNavigation.row(app, "playback.autoplayNextEpisode"))
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(["On", "Off"].contains(after))
        TVTest.capture("05-autoplay-flipped", in: self)

        TVTest.remote.press(.select)
        TVTest.settle(0.5)
        XCTAssertEqual(value(of: YouNavigation.row(app, "playback.autoplayNextEpisode")), before)
    }

    func testLibrariesToggleAndReset() {
        let app = TVTest.launch()
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.libraries")
        XCTAssertTrue(YouNavigation.row(app, "library.1").waitForExistence(timeout: 20))
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "library.1"))
        TVTest.settle()
        TVTest.capture("01-libraries", in: self)
        XCTAssertFalse(YouNavigation.row(app, "libraries.reset").exists)

        TVTest.remote.press(.select)
        TVTest.settle(0.5)
        XCTAssertEqual(value(of: YouNavigation.row(app, "library.1")), "Off")
        XCTAssertTrue(YouNavigation.row(app, "libraries.reset").waitForExistence(timeout: 5))
        TVTest.capture("02-library-off-reset-offered", in: self)

        YouNavigation.openRow(app, "libraries.reset")
        XCTAssertEqual(value(of: YouNavigation.row(app, "library.1")), "On")
        XCTAssertFalse(YouNavigation.row(app, "libraries.reset").exists)
        TVTest.capture("03-after-reset", in: self)
    }

    func testRebuildingTheTabBarDoesNotStealFocusFromTheLibrariesList() {
        let app = TVTest.launch()
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.libraries")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "library.1"))
        restoreDefaultLibraries(app)
        let tabBar = app.tabBars.firstMatch
        let tabsBefore = tabBar.buttons.allElementsBoundByIndex.map(\.label)
        TVTest.settle()

        TVTest.remote.press(.select)
        TVTest.settle(2)
        TVTest.capture("01-library-off-tab-removed", in: self)
        XCTAssertNotEqual(tabBar.buttons.allElementsBoundByIndex.map(\.label), tabsBefore, "switching a library off rebuilds the tab bar")
        XCTAssertEqual(value(of: YouNavigation.row(app, "library.1")), "Off")
        XCTAssertTrue(YouNavigation.row(app, "library.1").hasFocus, "the tab rebuild must leave focus in the list")

        TVTest.remote.press(.select)
        TVTest.settle(2)
        TVTest.capture("02-library-on-tab-restored", in: self)
        XCTAssertEqual(tabBar.buttons.allElementsBoundByIndex.map(\.label), tabsBefore)
        XCTAssertEqual(value(of: YouNavigation.row(app, "library.1")), "On")
        XCTAssertTrue(YouNavigation.row(app, "library.1").hasFocus)
    }

    func testMenuPopsWhileTheLibrariesLoadAndWhenTheyCannotBeLoaded() {
        let app = TVTest.launch(
            mock: ["MOCK_HIDDEN_SECTIONS": "1,2,3,4,5,6"],
            extraEnvironment: ["CRUCIBLE_FRESH": "1"]
        )
        YouNavigation.openYouTab(app)
        Self.setMockLatency(4000)
        YouNavigation.moveFocus(app, to: "you.libraries")
        TVTest.remote.press(.select)
        XCTAssertTrue(app.staticTexts["Loading Libraries"].waitForExistence(timeout: 5), "the screen should show its loading state")
        TVTest.capture("01-libraries-loading", in: self)
        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.libraries"), "Menu while the libraries load must pop to the You list")

        Self.setMockLatency(0)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 15), "an empty library list after the request is an error with Try Again")
        TVTest.settle()
        TVTest.capture("02-libraries-error", in: self)
        XCTAssertTrue(TVTest.waitForFocus(app.buttons["Try Again"]))
        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "you.libraries"), "Menu on the error state must pop to the You list")
    }

    func testServerShowsRoutesAndConnectionState() {
        let app = TVTest.launch()
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.server")
        let status = YouNavigation.row(app, "server.card")
        XCTAssertTrue(YouNavigation.row(app, "server.test").waitForExistence(timeout: 20))
        TVTest.capture("01-server-checking", in: self)
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        let connected = NSPredicate(format: "label CONTAINS 'Connected'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: connected, object: status)], timeout: 30), .completed)
        TVTest.settle()
        TVTest.capture("02-server-connected", in: self)

        YouNavigation.moveFocus(app, to: "server.preferLocal")
        let before = value(of: YouNavigation.row(app, "server.preferLocal"))
        TVTest.remote.press(.select)
        TVTest.settle(0.5)
        XCTAssertNotEqual(value(of: YouNavigation.row(app, "server.preferLocal")), before)
        TVTest.capture("03-prefer-local-flipped", in: self)
        TVTest.remote.press(.select)

        TVTest.remote.press(.up)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "server.test"))
        TVTest.remote.press(.select)
        TVTest.capture("04-test-connection-running", in: self)
        YouNavigation.moveFocus(app, to: "server.switchServer")
        TVTest.capture("05-switch-server-focused", in: self)
    }

    func testAddServerByAddressReportsErrors() {
        let app = TVTest.launch()
        openAddServer(app)
        TVTest.capture("01-add-server", in: self)

        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "addServer.connect"))
        TVTest.remote.press(.select)
        XCTAssertTrue(app.staticTexts["addServer.error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["addServer.error"].label.hasPrefix("Enter an address like"))
        TVTest.settle()
        TVTest.capture("02-empty-address-error", in: self)

        enterAddress("127.0.0.1:1", in: app)
        let notFound = app.staticTexts["addServer.error"]
        XCTAssertTrue(notFound.waitForExistence(timeout: 30))
        XCTAssertTrue(notFound.label.hasPrefix("Couldn't find a Plex server at 127.0.0.1:1"))
        TVTest.settle()
        TVTest.capture("03-server-not-found", in: self)
    }

    func testAddServerByAddressPinsTheServerAndReconnects() throws {
        let mock = try XCTUnwrap(ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"].flatMap(URL.init(string:)))
        let address = "\(mock.host ?? "127.0.0.1"):\(mock.port ?? 32400)"
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_PLEXTV": mock.absoluteString])
        openAddServer(app)
        enterAddress(address, in: app)
        TVTest.settle(5)
        TVTest.capture("00-after-connect", in: self)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60), "a found server should relaunch the main UI")
        TVTest.settle(2)
        TVTest.capture("01-reconnected", in: self)

        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.server")
        XCTAssertTrue(YouNavigation.row(app, "server.test").waitForExistence(timeout: 20))
        let connected = NSPredicate(format: "label CONTAINS 'Connected'")
        let card = YouNavigation.row(app, "server.card")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: connected, object: card)], timeout: 40), .completed)
        TVTest.settle()
        TVTest.capture("02-routes-after-add", in: self)
    }

    private func openAddServer(_ app: XCUIApplication) {
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.server")
        YouNavigation.openRow(app, "server.addServer")
        XCTAssertTrue(app.textFields["addServer.address"].waitForExistence(timeout: 15))
        TVTest.settle()
    }

    private func enterAddress(_ address: String, in app: XCUIApplication) {
        if !YouNavigation.row(app, "addServer.address").hasFocus {
            TVTest.remote.press(.up)
        }
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "addServer.address"))
        TVTest.remote.press(.select)
        TVTest.settle(2)
        app.typeText(address)
        app.typeText("\n")
        TVTest.settle(1)
    }

    func testServerCardAndContextPanelsAreReachableByFocusWhileVoiceOverRuns() {
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_VOICEOVER": "1"])
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.server")
        XCTAssertTrue(YouNavigation.row(app, "server.test").waitForExistence(timeout: 20))
        TVTest.settle(2)
        TVTest.remote.press(.left)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "server.card"), "the server card must be a focus stop for VoiceOver")
        XCTAssertTrue(YouNavigation.row(app, "server.card").label.hasPrefix("Marcus-PC"))
        TVTest.capture("01-server-card-focused", in: self)
        TVTest.remote.press(.menu)

        YouNavigation.moveFocusUp(app, to: "you.playback")
        TVTest.remote.press(.select)
        XCTAssertTrue(YouNavigation.row(app, "playback.streamingQuality").waitForExistence(timeout: 10))
        TVTest.remote.press(.left)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "settings.context"))
        XCTAssertTrue(YouNavigation.row(app, "settings.context").label.hasPrefix("Playback"))
        TVTest.capture("02-playback-heading-focused", in: self)
    }

    func testDiagnosticsPanelsAndLogAreReadableByVoiceOver() {
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_VOICEOVER": "1"])
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.diagnostics")
        let log = YouNavigation.row(app, "diagnostics.log")
        XCTAssertTrue(log.waitForExistence(timeout: 15))
        TVTest.settle(2)
        XCTAssertTrue((log.value as? String ?? "").contains("[NOTE]"), "the log must expose its text as its accessibility value")
        TVTest.remote.press(.left)
        TVTest.settle(1)
        TVTest.capture("00-after-left-from-log", in: self)
        YouNavigation.moveFocusUp(app, to: "diagnostics.counts", limit: 4)
        XCTAssertTrue(YouNavigation.row(app, "diagnostics.counts").label.hasPrefix("Log lines"))
        TVTest.capture("01-counts-focused", in: self)
    }

    func testAboutContextIsReachableByFocusWhileVoiceOverRuns() {
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_VOICEOVER": "1"])
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.about")
        XCTAssertTrue(YouNavigation.row(app, "about.version").waitForExistence(timeout: 15))
        TVTest.settle()
        TVTest.remote.press(.left)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "about.context"))
        XCTAssertTrue(YouNavigation.row(app, "about.context").label.hasPrefix("Crucible. Version"))
        TVTest.capture("01-about-context-focused", in: self)
    }

    func testDiagnosticsShowsLogAndScrolls() {
        let app = TVTest.launch()
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.diagnostics")
        let log = YouNavigation.row(app, "diagnostics.log")
        XCTAssertTrue(log.waitForExistence(timeout: 15))
        TVTest.settle(1.5)
        TVTest.capture("00-diagnostics-on-open", in: self)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "diagnostics.log"))
        TVTest.capture("01-diagnostics", in: self)

        for _ in 0..<3 { TVTest.remote.press(.up) }
        TVTest.settle()
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "diagnostics.log"), "Up inside the log scrolls it, it must not leave the log")
        TVTest.capture("02-log-scrolled-up", in: self)

        TVTest.remote.press(.left)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "diagnostics.clearCache"))
        TVTest.remote.press(.up)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "diagnostics.refresh"))
        TVTest.remote.press(.down)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "diagnostics.clearCache"))
        TVTest.remote.press(.select)
        XCTAssertTrue(app.alerts["Clear Image Cache?"].waitForExistence(timeout: 10))
        TVTest.settle()
        TVTest.capture("03-clear-cache-confirmation", in: self)
        TVTest.remote.press(.menu)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "diagnostics.clearCache"))
    }

    func testAboutShowsVersionLicenseAndCredits() {
        let app = TVTest.launch()
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.about")
        XCTAssertTrue(YouNavigation.row(app, "about.version").waitForExistence(timeout: 15))
        XCTAssertTrue(YouNavigation.row(app, "about.credit.GRDB.swift").exists)
        TVTest.settle()
        TVTest.capture("01-about", in: self)
        YouNavigation.moveFocus(app, to: "about.credit.GRDB.swift")
        TVTest.capture("02-about-credit-focused", in: self)
    }
}
