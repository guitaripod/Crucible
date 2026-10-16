import Testing
@testable import CrucibleCore

struct DemoPhoneFinaleGateTests {
    private let quiet = DemoPhoneFinaleGate.Screen(appIsActive: true, hasModal: false, inTransition: false)

    @Test func itWaitsForAQuietScreenAcrossTwoChecks() {
        var streak = 0
        #expect(DemoPhoneFinaleGate.decision(demoIsActive: true, screen: quiet, quietChecks: streak) == .wait)
        streak = DemoPhoneFinaleGate.quietChecks(after: quiet, previous: streak)
        #expect(DemoPhoneFinaleGate.decision(demoIsActive: true, screen: quiet, quietChecks: streak) == .present)
    }

    @Test func itNeverAppearsOverAModalOrTheBackground() {
        let player = DemoPhoneFinaleGate.Screen(appIsActive: true, hasModal: true, inTransition: false)
        let background = DemoPhoneFinaleGate.Screen(appIsActive: false, hasModal: false, inTransition: false)
        let moving = DemoPhoneFinaleGate.Screen(appIsActive: true, hasModal: false, inTransition: true)
        let typing = DemoPhoneFinaleGate.Screen(appIsActive: true, hasModal: false, inTransition: false, keyboardIsUp: true)
        for screen in [player, background, moving, typing] {
            #expect(DemoPhoneFinaleGate.decision(demoIsActive: true, screen: screen, quietChecks: 5) == .wait)
        }
    }

    @Test func aBusyScreenRestartsTheQuietStreak() {
        let player = DemoPhoneFinaleGate.Screen(appIsActive: true, hasModal: true, inTransition: false)
        #expect(DemoPhoneFinaleGate.quietChecks(after: player, previous: 1) == 0)
        #expect(DemoPhoneFinaleGate.quietChecks(after: quiet, previous: 1) == 2)
    }

    @Test func anInstallThatOwnsProNeverSeesTheFinale() {
        #expect(DemoPhoneFinaleGate.decision(demoIsActive: true, ownsPro: true, screen: quiet, quietChecks: 5) == .drop)
    }

    @Test func itIsDroppedOnceTheDemoIsLeft() {
        #expect(DemoPhoneFinaleGate.decision(demoIsActive: false, screen: quiet, quietChecks: 5) == .drop)
    }
}
