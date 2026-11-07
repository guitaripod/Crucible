import XCTest

/// The server owner's tools on Apple TV, against the mock, whose plex.tv says the account owns the server: Stop Stream in Server
/// Activity's long-press menu, the Server Dashboard under You, Manage (Refresh, Fix Match, Edit Details, artwork) in a title's
/// long-press menu on Home, and Manage on a library's header.
@MainActor
final class OwnerToolsTests: TVTestCase {
    private var mockURL: String { ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"] ?? "" }

    /// Presses Down until the open menu's item labelled `label` has focus; returns whether it got there.
    private func focusMenuItem(_ app: XCUIApplication, _ label: String, limit: Int = 12) -> Bool {
        for _ in 0..<limit {
            if focusIsOn(app, label) { return true }
            TVTest.remote.press(.down)
            TVTest.settle(0.5)
        }
        return focusIsOn(app, label)
    }

    /// A menu item takes focus as an unlabelled cell whose child carries the title.
    private func focusIsOn(_ app: XCUIApplication, _ label: String) -> Bool {
        let focused = AppNavigation.focusedElement(app)
        return focused.label == label || focused.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).count > 0
    }

    private func mockJSON(_ path: String) -> [String: Any]? {
        guard let url = URL(string: mockURL + path), let data = TVTest.fetch(url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func mockItem(_ ratingKey: String) -> [String: Any]? {
        let container = mockJSON("/library/metadata/\(ratingKey)")?["MediaContainer"] as? [String: Any]
        return (container?["Metadata"] as? [[String: Any]])?.first
    }

    /// Moves focus within an alert until its button labelled `label` has it. tvOS 26 lays the buttons out side by side and older
    /// systems stack them, so both axes are tried.
    private func focusAlertButton(_ app: XCUIApplication, _ label: String) -> Bool {
        for direction in [XCUIRemote.Button.down, .right, .left, .up] {
            if AppNavigation.focusedElement(app).label == label { return true }
            TVTest.remote.press(direction)
            TVTest.settle(0.5)
        }
        return AppNavigation.focusedElement(app).label == label
    }

    /// Opens the long-press menu of a Continue Watching card on Home (the first, or the one with rating key `card`) and its
    /// Manage submenu; returns the card's rating key.
    private func openManageMenu(_ app: XCUIApplication, card: String? = nil) -> String {
        XCTAssertTrue(AppNavigation.move(app, .down, untilFocusHasPrefix: "home.card.continueWatching.", limit: 6), "focus never reached Continue Watching")
        if let card {
            XCTAssertTrue(AppNavigation.move(app, .right, untilFocusHasPrefix: "home.card.continueWatching.\(card)", limit: 6), "focus never reached card \(card)")
        }
        let key = AppNavigation.focusedIdentifier(app).replacingOccurrences(of: "home.card.continueWatching.", with: "")
        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1.0)
        XCTAssertTrue(app.descendants(matching: .any)["Manage"].waitForExistence(timeout: 5), "the owner's title menu has no Manage")
        XCTAssertTrue(focusMenuItem(app, "Manage"), "focus never reached Manage")
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        return key
    }

    func testTheDashboardShowsLoadTasksAndTheUpdate() {
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_PLEXTV": mockURL])
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.dashboard")
        let load = AppNavigation.element(app, "dashboard.load")
        XCTAssertTrue(load.waitForExistence(timeout: 20), "the dashboard shows no load")
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "dashboard.update", timeout: 20) || AppNavigation.element(app, "dashboard.update").waitForExistence(timeout: 20), "the dashboard offers no server update")
        XCTAssertTrue((load.value as? String ?? load.label).contains("CPU"), "the load row reads \(load.label)")
        TVTest.capture("05-dashboard", in: self)
        YouNavigation.moveFocus(app, to: "dashboard.update")
        TVTest.remote.press(.select)
        let notes = app.alerts.firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 10), "the update showed no release notes")
        XCTAssertTrue(notes.buttons["Install Now"].exists)
        TVTest.capture("06-release-notes", in: self)
        TVTest.remote.press(.menu)
    }

    func testFixMatchListsCandidatesAndMatchesOne() {
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_PLEXTV": mockURL])
        _ = openManageMenu(app, card: "1002")
        XCTAssertTrue(focusMenuItem(app, "Fix Match…"), "Manage offers no Fix Match")
        TVTest.remote.press(.select)
        let first = AppNavigation.firstElement(app, prefix: "fixMatch.result.")
        XCTAssertTrue(first.waitForExistence(timeout: 20), "Fix Match listed no candidates")
        TVTest.settle(1)
        TVTest.capture("07-fix-match", in: self)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'fixMatch.result.'")).count, 3)
        YouNavigation.moveFocus(app, to: "fixMatch.search")
        TVTest.remote.press(.down)
        TVTest.remote.press(.down)
        TVTest.remote.press(.select)
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "picking a candidate asked for no confirmation")
        TVTest.capture("08-fix-match-confirm", in: self)
        XCTAssertTrue(confirm.buttons["Match"].exists)
        XCTAssertTrue(focusAlertButton(app, "Match"), "focus never reached Match")
        TVTest.remote.press(.select)
        XCTAssertTrue(TVTest.waitForNoElement(AppNavigation.element(app, "fixMatch.search"), timeout: 20), "Fix Match stayed open after matching")
    }

    func testEditDetailsOpensTheKeyboardAndSavesWhatChanged() {
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_PLEXTV": mockURL])
        let key = openManageMenu(app)
        XCTAssertTrue(focusMenuItem(app, "Edit Details…"), "Manage offers no Edit Details")
        TVTest.remote.press(.select)
        let title = AppNavigation.element(app, "editDetails.title")
        XCTAssertTrue(title.waitForExistence(timeout: 20), "Edit Details shows no Title row")
        XCTAssertFalse(AppNavigation.element(app, "editDetails.save").isEnabled, "Save is on before anything changed")
        let original = mockItem(key)?["title"] as? String ?? ""
        TVTest.settle(1)
        TVTest.remote.press(.select)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Select on Title opened no text field")
        TVTest.remote.press(.select)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "Select on the text field opened no keyboard")
        TVTest.settle(1.5)
        app.typeText("!")
        TVTest.settle(1)
        TVTest.capture("09-edit-title", in: self)
        for _ in 0..<6 where AppNavigation.focusedElement(app).label.lowercased() != "done" {
            TVTest.remote.press(.down)
            TVTest.settle(0.4)
        }
        XCTAssertEqual(AppNavigation.focusedElement(app).label.lowercased(), "done", "focus never reached the keyboard's done button")
        TVTest.remote.press(.select)
        TVTest.settle(1)
        XCTAssertTrue(app.alerts.firstMatch.buttons["Done"].exists, "the alert has no Done button")
        XCTAssertTrue(focusAlertButton(app, "Done"), "focus never reached Done")
        TVTest.remote.press(.select)
        TVTest.settle(1)
        XCTAssertTrue(AppNavigation.element(app, "editDetails.save").isEnabled, "Save stayed off after editing the title")
        YouNavigation.moveFocus(app, to: "editDetails.save")
        TVTest.remote.press(.select)
        XCTAssertTrue(TVTest.waitForNoElement(AppNavigation.element(app, "editDetails.save"), timeout: 20), "Edit Details stayed open after saving")
        TVTest.settle(1)
        XCTAssertEqual(mockItem(key)?["title"] as? String, original + "!", "the server never got the new title")
    }

    func testChoosingAnotherPosterChangesTheTitlesPoster() {
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_PLEXTV": mockURL])
        let key = openManageMenu(app)
        XCTAssertTrue(focusMenuItem(app, "Choose Poster…"), "Manage offers no Choose Poster")
        TVTest.remote.press(.select)
        let first = AppNavigation.firstElement(app, prefix: "grid.")
        XCTAssertTrue(first.waitForExistence(timeout: 20), "the poster picker listed nothing")
        TVTest.settle(1.5)
        TVTest.capture("10-poster-picker", in: self)
        let before = mockItem(key)?["thumb"] as? String
        TVTest.remote.press(.right)
        TVTest.settle(0.5)
        TVTest.remote.press(.select)
        XCTAssertTrue(TVTest.waitForNoElement(first, timeout: 20), "the picker stayed open after choosing")
        TVTest.settle(1)
        XCTAssertNotEqual(mockItem(key)?["thumb"] as? String, before, "the title kept its poster")
    }

    func testALibraryHeaderOffersManageAndScans() {
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_PLEXTV": mockURL])
        AppNavigation.selectTab("Movies", in: app)
        let manage = AppNavigation.element(app, "tv.library.manage")
        XCTAssertTrue(manage.waitForExistence(timeout: 30), "the library header has no Manage button for the owner")
        TVTest.settle(1.5)
        TVTest.remote.press(.down)
        TVTest.settle(0.8)
        XCTAssertTrue(AppNavigation.move(app, .up, untilFocusHasPrefix: "tv.chip.all", limit: 4))
        XCTAssertTrue(AppNavigation.move(app, .right, untilFocusHasPrefix: "tv.library.manage", limit: 12), "focus never reached Manage")
        TVTest.remote.press(.select)
        TVTest.settle(1)
        XCTAssertTrue(focusMenuItem(app, "Scan Library Files"), "Manage offers no Scan Library Files")
        TVTest.capture("11-library-manage", in: self)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.alerts["Sent to Your Server"].waitForExistence(timeout: 15), "scanning gave no word that the server took it")
        let activities = (mockJSON("/activities")?["MediaContainer"] as? [String: Any])?["Activity"] as? [[String: Any]]
        XCTAssertEqual(activities?.count, 1, "the mock never saw the scan")
    }

    func testEveryControlOfAnOwnersLibraryHeaderTakesTheFocusOnScreen() {
        walkLibraryHeader(arguments: [], capture: "12-library-header")
    }

    func testEveryControlOfAnOwnersLibraryHeaderTakesTheFocusOnScreenInGerman() {
        walkLibraryHeader(arguments: ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"], capture: "13-library-header-german")
    }

    /// Walks the owner's Movies header from All to Folders and back: every control must take the focus in order, lie whole on
    /// the screen while it has it and keep clear of its neighbours. A row wider than the screen used to squeeze its chips to
    /// "…", push Folders off the screen and strand the focus.
    private func walkLibraryHeader(arguments: [String], capture: String) {
        continueAfterFailure = false
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_PLEXTV": mockURL], arguments: arguments)
        AppNavigation.selectTab("Movies", in: app)
        XCTAssertTrue(AppNavigation.element(app, "tv.library.manage").waitForExistence(timeout: 30), "the library header has no Manage button for the owner")
        XCTAssertTrue(AppNavigation.element(app, "tv.library.filters").waitForExistence(timeout: 30), "the library header has no Filters button")
        XCTAssertTrue(AppNavigation.element(app, "tv.library.genre").waitForExistence(timeout: 30), "the library header has no Genre button")
        TVTest.settle(1.5)
        TVTest.remote.press(.down)
        TVTest.settle(0.8)
        XCTAssertTrue(AppNavigation.move(app, .up, untilFocusHasPrefix: "tv.chip.all", limit: 4), "focus never reached All")
        let order = [
            "tv.chip.all", "tv.chip.unwatched", "tv.chip.inProgress", "tv.library.genre", "tv.library.sort",
            "tv.library.filters", "tv.library.manage", "tv.library.collections", "tv.library.folders",
        ]
        let screen = app.windows.firstMatch.frame
        assertSideBySide(order, in: app)
        for (index, identifier) in order.enumerated() {
            if index > 0 { TVTest.remote.press(.right) }
            XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: identifier, timeout: 5), "Right went to \(AppNavigation.focusedIdentifier(app)), not \(identifier)")
            TVTest.settle(0.6)
            let frame = AppNavigation.element(app, identifier).frame
            XCTAssertTrue(screen.contains(frame), "\(identifier) has the focus at \(frame), not whole on the screen \(screen)")
        }
        TVTest.capture("\(capture)-folders", in: self)
        assertSideBySide(order, in: app)
        for identifier in order.reversed().dropFirst() {
            TVTest.remote.press(.left)
            XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: identifier, timeout: 5), "Left went to \(AppNavigation.focusedIdentifier(app)), not \(identifier)")
            TVTest.settle(0.6)
            XCTAssertTrue(screen.contains(AppNavigation.element(app, identifier).frame), "\(identifier) has the focus off the screen")
        }
        TVTest.capture("\(capture)-all", in: self)
    }

    /// The controls `order` names lie left to right in that order, each clear of the next, at one moment of the row's scroll.
    private func assertSideBySide(_ order: [String], in app: XCUIApplication) {
        let frames = order.map { AppNavigation.element(app, $0).frame }
        for (index, pair) in zip(frames, frames.dropFirst()).enumerated() {
            XCTAssertGreaterThan(pair.1.minX, pair.0.maxX, "\(order[index + 1]) at \(pair.1) overlaps \(order[index]) at \(pair.0)")
        }
    }

    func testStoppingAStreamTakesItOffServerActivity() {
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_PLEXTV": mockURL])
        YouNavigation.openYouTab(app)
        YouNavigation.openRow(app, "you.activity")
        let stream = AppNavigation.element(app, "grid.1001")
        XCTAssertTrue(stream.waitForExistence(timeout: 30), "Server Activity shows no stream of Halcyon")
        XCTAssertTrue(AppNavigation.move(app, .left, untilFocusHasPrefix: "grid.1001", limit: 3), "focus never reached the Halcyon stream")
        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1.0)
        XCTAssertTrue(app.descendants(matching: .any)["Stop Stream…"].waitForExistence(timeout: 5), "the owner's stream menu has no Stop Stream")
        XCTAssertTrue(focusMenuItem(app, "Stop Stream…"), "focus never reached Stop Stream")
        TVTest.capture("01-stop-stream", in: self)
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        XCTAssertTrue(focusMenuItem(app, "Maintenance, back soon."), "Stop Stream offers no reasons")
        TVTest.capture("02-reasons", in: self)
        TVTest.remote.press(.select)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stream)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 20), .completed, "the stopped stream stayed in Server Activity")
        XCTAssertTrue(AppNavigation.element(app, "grid.4012").exists, "the other stream went too")
    }

    func testATitlesMenuOffersManageAndRefreshesItsMetadata() {
        let app = AppNavigation.launchHome(extraEnvironment: ["CRUCIBLE_PLEXTV": mockURL])
        XCTAssertTrue(AppNavigation.move(app, .down, untilFocusHasPrefix: "home.card.continueWatching.", limit: 6), "focus never reached Continue Watching")
        TVTest.remote.longPress(.select, duration: 1.6)
        TVTest.settle(1.0)
        XCTAssertTrue(app.descendants(matching: .any)["Manage"].waitForExistence(timeout: 5), "the owner's title menu has no Manage")
        XCTAssertTrue(focusMenuItem(app, "Manage"), "focus never reached Manage")
        TVTest.remote.press(.select)
        TVTest.settle(1.0)
        XCTAssertTrue(focusMenuItem(app, "Refresh Metadata"), "Manage offers no Refresh Metadata")
        TVTest.capture("03-manage", in: self)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.alerts["Sent to Your Server"].waitForExistence(timeout: 15), "refreshing gave no word that the server took it")
        TVTest.capture("04-sent", in: self)
    }
}
