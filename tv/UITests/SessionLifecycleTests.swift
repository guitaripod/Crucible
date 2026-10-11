import XCTest

/// The account lifecycle seen from the launch gate: an expired or revoked Plex sign-in must say so
/// and offer Sign In Again and Sign Out instead of a retry loop. The mock rejects every token on
/// request (`/mock/plextv-config?reject_token=1`).
@MainActor
final class SessionLifecycleTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private var mockURL: String {
        ProcessInfo.processInfo.environment["CRUCIBLE_MOCK"] ?? ""
    }

    private func configureMock(rejectToken: Bool, polls: Int = 1) {
        guard let url = URL(string: "\(mockURL)/mock/plextv-config?pin_polls=\(polls)&pin_expires=900&servers=default&reject_token=\(rejectToken ? 1 : 0)") else {
            XCTFail("CRUCIBLE_MOCK is not set: start the mock with tv.sh mock-up")
            return
        }
        let done = expectation(description: "mock configured")
        URLSession.shared.dataTask(with: url) { _, response, _ in
            if (response as? HTTPURLResponse)?.statusCode != 200 { XCTFail("mock refused the plex.tv configuration") }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
    }

    private func launchWithRevokedToken() -> XCUIApplication {
        configureMock(rejectToken: true)
        return TVTest.launch(extraEnvironment: ["CRUCIBLE_MOCK": mockURL, "CRUCIBLE_PLEXTV": mockURL])
    }

    func testARevokedSignInSaysSoAndOffersSignInAgainAndSignOut() {
        let app = launchWithRevokedToken()
        XCTAssertTrue(app.buttons["launch.signInAgain"].waitForExistence(timeout: 90))
        XCTAssertTrue(app.buttons["launch.signOut"].exists)
        XCTAssertFalse(app.buttons["launch.retry"].isHittable, "an expired sign-in must not offer a retry loop")
        XCTAssertTrue(app.staticTexts["Your Plex sign-in expired"].exists)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "launch.signInAgain"))
        TVTest.settle()
        TVTest.capture("01-sign-in-expired", in: self)
    }

    func testSigningInAgainKeepsTheServerAndRelaunches() {
        let app = launchWithRevokedToken()
        XCTAssertTrue(app.buttons["launch.signInAgain"].waitForExistence(timeout: 90))
        configureMock(rejectToken: false)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "onboarding.code").firstMatch.waitForExistence(timeout: 20), "Sign In Again must open the link code")
        TVTest.settle(1)
        TVTest.capture("02-sign-in-again-code", in: self)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 90), "approving the code must relaunch the app on the saved server")
    }

    func testSigningOutFromTheGateAsksFirstThenReturnsToWelcome() {
        let app = launchWithRevokedToken()
        XCTAssertTrue(app.buttons["launch.signOut"].waitForExistence(timeout: 90))
        TVTest.remote.press(.right)
        XCTAssertTrue(TVTest.waitForFocus(on: app, identifier: "launch.signOut"))
        TVTest.remote.press(.select)
        XCTAssertTrue(app.alerts["Sign Out?"].waitForExistence(timeout: 10))
        TVTest.settle()
        TVTest.capture("03-sign-out-confirmation", in: self)
        let confirm = app.alerts["Sign Out?"].buttons["Sign Out"].firstMatch
        if !confirm.hasFocus { TVTest.remote.press(.right) }
        XCTAssertTrue(confirm.hasFocus)
        TVTest.remote.press(.select)
        XCTAssertTrue(app.buttons["onboarding.signIn"].waitForExistence(timeout: 20), "signing out returns to Welcome")
        TVTest.settle()
        TVTest.capture("04-welcome-after-sign-out", in: self)
    }
}
