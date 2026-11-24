import XCTest

/// Entering the app — a cold launch, or an Apple TV woken with Crucible in front — reads Home and the server's progress again,
/// and never hands the server a position older than what another client has watched since: the two halves of progress staying
/// in step, seen from the Apple TV.
@MainActor
final class EntrySyncTests: PlayerTestCase {
    /// A launch that starts without the positions an earlier test's app saved, so the progress a test sets on the mock is the
    /// only one the app can know.
    private static let withoutDevicePositions = ["-playbackResumePoints", "<data></data>"]

    override func tearDown() {
        Mock.get("/mock/hubs?mode=ok")
        super.tearDown()
    }

    /// Watch on another device while the Apple TV is away: coming back to Home shows where the other device left off, not the
    /// position the Apple TV last read.
    func testHomeReadsTheServerAgainWhenTheAppIsEntered() {
        setProgress(Self.episode, seconds: 200)
        let app = TVTest.launch(arguments: Self.withoutDevicePositions)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60))
        let card = continueWatchingCard(in: app, ratingKey: Self.episode)
        XCTAssertTrue(card.waitForExistence(timeout: 30), "Continue Watching should lead with the episode")
        XCTAssertTrue(card.label.contains("41 min left"), "Home leads with \(card.label)")
        TVTest.capture("01-entered-before", in: self)

        TVTest.remote.press(.home)
        TVTest.settle(4)
        setProgress(Self.episode, seconds: 1_800)
        TVTest.settle(1)

        app.activate()
        XCTAssertTrue(
            waitForContinueWatchingCard(in: app, ratingKey: Self.episode, containing: "15 min left", timeout: 40),
            "Home kept the position from before the app was away: \(continueWatchingCard(in: app, ratingKey: Self.episode).label)"
        )
        TVTest.capture("02-entered-caught-up", in: self)
    }

    /// Home comes back before the network does after a wake from sleep: the Apple TV keeps trying, and catches up as soon as the
    /// server answers, without a further event or a second visit to Home.
    func testHomeKeepsTryingWhenTheServerIsNotBackYetOnEntry() {
        setProgress(Self.episode, seconds: 200)
        let app = TVTest.launch(arguments: Self.withoutDevicePositions)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 60))
        XCTAssertTrue(continueWatchingCard(in: app, ratingKey: Self.episode).waitForExistence(timeout: 30))

        TVTest.remote.press(.home)
        TVTest.settle(4)
        Mock.get("/mock/hubs?mode=unavailable")
        setProgress(Self.episode, seconds: 1_800)

        app.activate()
        TVTest.settle(10)
        TVTest.capture("01-entered-while-the-server-is-out", in: self)
        Mock.get("/mock/hubs?mode=ok")

        XCTAssertTrue(
            waitForContinueWatchingCard(in: app, ratingKey: Self.episode, containing: "15 min left", timeout: 40),
            "Home gave up rather than trying again once the server answered: \(continueWatchingCard(in: app, ratingKey: Self.episode).label)"
        )
        TVTest.capture("02-entered-recovered", in: self)
    }

    private func continueWatchingCard(in app: XCUIApplication, ratingKey: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "home.card.continueWatching.\(ratingKey)").firstMatch
    }

    /// Waits for Home's Continue Watching card of `ratingKey` to say `text`, which is what its line of time left carries: the
    /// card is reconfigured in place when a read lands, so the label is asked again rather than a second element looked for.
    private func waitForContinueWatchingCard(
        in app: XCUIApplication,
        ratingKey: String,
        containing text: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if continueWatchingCard(in: app, ratingKey: ratingKey).label.contains(text) { return true }
            TVTest.settle(1)
        }
        return false
    }
}
