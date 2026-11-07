import XCTest

/// Drives the Apple TV Home screen itself. With Crucible Pro the app publishes its Top Shelf; the system carousel
/// (HeadBoard) then plays the scene where the viewer stopped, streamed from the mock server, once focus rests on the
/// first Continue Watching card, and its details lay out the snapshot's context line, genre, episode, next episode and
/// cast. Crucible has to sit in the Home screen's top row, which it does on the test simulators.
@MainActor
final class TopShelfTests: TVTestCase {
    private let board = XCUIApplication(bundleIdentifier: "com.apple.HeadBoard")

    override func setUp() {
        continueAfterFailure = false
    }

    func testTheCarouselPlaysTheSceneWhereTheViewerStoppedAndShowsTheCardsDetails() throws {
        let app = TVTest.launch(extraEnvironment: ["CRUCIBLE_PRO": "lifetime"])
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60))
        TVTest.settle(10)
        let previewsBefore = try previewRequests()

        TVTest.remote.press(.home)
        TVTest.settle(4)
        try focusCrucible()
        TVTest.remote.press(.up)
        XCTAssertTrue(waitForPreview(after: previewsBefore), "the carousel never asked the server for the scene preview")
        TVTest.settle(3)
        TVTest.capture("01-scene-preview", in: self)

        TVTest.remote.press(.select)
        let context = board.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Continue Watching'")).firstMatch
        XCTAssertTrue(context.waitForExistence(timeout: 15), "the carousel never showed the card's details")
        XCTAssertTrue(board.staticTexts["The Salt Road"].exists)
        XCTAssertTrue(board.staticTexts["Drama"].exists)
        let attributes = board.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Episode S2 · E4 · Low Tide'")).firstMatch
        XCTAssertTrue(attributes.exists, "the episode attribute is missing")
        XCTAssertTrue(attributes.label.contains("Next Episode E5 · Undertow"), attributes.label)
        XCTAssertTrue(attributes.label.contains("Starring"), attributes.label)
        TVTest.capture("02-continue-watching-details", in: self)

        TVTest.remote.press(.right)
        let director = board.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Director'")).firstMatch
        XCTAssertTrue(director.waitForExistence(timeout: 10), "the movie card shows no director")
        TVTest.settle(1)
        TVTest.capture("03-movie-details", in: self)
        TVTest.remote.press(.menu)
        TVTest.remote.press(.menu)
    }

    /// Moves along the Home screen's top row to Crucible's icon, from its start.
    private func focusCrucible() throws {
        let icon = board.descendants(matching: .any).matching(NSPredicate(format: "label == 'Crucible'")).firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 10), "Crucible is not on the Home screen")
        for _ in 0..<6 {
            TVTest.remote.press(.left)
            TVTest.settle(0.5)
        }
        for _ in 0..<8 where !icon.hasFocus {
            TVTest.remote.press(.right)
            TVTest.settle(0.8)
        }
        XCTAssertTrue(icon.hasFocus, "Crucible's icon never took focus")
        TVTest.settle(3)
    }

    private func waitForPreview(after count: Int, timeout: TimeInterval = 40) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let now = try? previewRequests(), now > count { return true }
            TVTest.settle(2)
        }
        return false
    }

    private func previewRequests() throws -> Int {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"])
        var components = try XCTUnwrap(URLComponents(string: base + "/mock/requests"))
        components.queryItems = [URLQueryItem(name: "contains", value: "/video/:/transcode/universal/start.m3u8?path=/library/metadata/")]
        let data = try XCTUnwrap(TVTest.fetch(try XCTUnwrap(components.url)))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Int]
        return try XCTUnwrap(object?["count"])
    }
}
