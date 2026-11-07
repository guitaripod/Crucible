import XCTest

/// Walks an owner's library header, the row a server owner sees with every control in it.
@MainActor
enum LibraryHeaderWalk {
    static let order = [
        "tv.chip.all", "tv.chip.unwatched", "tv.chip.inProgress", "tv.library.genre", "tv.library.sort",
        "tv.library.filters", "tv.library.manage", "tv.library.collections", "tv.library.folders",
    ]

    /// Walks the header of the library tab on screen from All to Folders and back: every control must take the focus in order,
    /// lie whole on the screen while it has it and keep clear of its neighbours. A row wider than the screen used to squeeze its
    /// chips to "…", push Folders off the screen and strand the focus.
    static func walk(_ app: XCUIApplication, capture: String, in test: XCTestCase) {
        XCTAssertTrue(AppNavigation.element(app, "tv.library.manage").waitForExistence(timeout: 30), "the library header has no Manage button for the owner")
        XCTAssertTrue(AppNavigation.element(app, "tv.library.filters").waitForExistence(timeout: 30), "the library header has no Filters button")
        XCTAssertTrue(AppNavigation.element(app, "tv.library.genre").waitForExistence(timeout: 30), "the library header has no Genre button")
        TVTest.settle(1.5)
        TVTest.remote.press(.down)
        TVTest.settle(0.8)
        XCTAssertTrue(AppNavigation.move(app, .up, untilFocusHasPrefix: "tv.chip.all", limit: 4), "focus never reached All")
        let screen = app.windows.firstMatch.frame
        assertSideBySide(app)
        for (index, identifier) in order.enumerated() {
            if index > 0 { TVTest.remote.press(.right) }
            XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: identifier, timeout: 5), "Right went to \(AppNavigation.focusedIdentifier(app)), not \(identifier)")
            TVTest.settle(0.6)
            let frame = AppNavigation.element(app, identifier).frame
            XCTAssertTrue(screen.contains(frame), "\(identifier) has the focus at \(frame), not whole on the screen \(screen)")
        }
        TVTest.capture("\(capture)-folders", in: test)
        assertSideBySide(app)
        for identifier in order.reversed().dropFirst() {
            TVTest.remote.press(.left)
            XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: identifier, timeout: 5), "Left went to \(AppNavigation.focusedIdentifier(app)), not \(identifier)")
            TVTest.settle(0.6)
            XCTAssertTrue(screen.contains(AppNavigation.element(app, identifier).frame), "\(identifier) has the focus off the screen")
        }
        TVTest.capture("\(capture)-all", in: test)
    }

    /// The controls lie left to right in `order`, each clear of the next, at one moment of the row's scroll.
    private static func assertSideBySide(_ app: XCUIApplication) {
        let frames = order.map { AppNavigation.element(app, $0).frame }
        for (index, pair) in zip(frames, frames.dropFirst()).enumerated() {
            XCTAssertGreaterThan(pair.1.minX, pair.0.maxX, "\(order[index + 1]) at \(pair.1) overlaps \(order[index]) at \(pair.0)")
        }
    }
}
