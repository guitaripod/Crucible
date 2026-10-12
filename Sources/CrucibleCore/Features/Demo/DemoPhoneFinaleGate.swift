import Foundation

/// When the soft paywall that closes the tour may appear: never over the player or another modal, never mid-transition, and only once
/// the screen has stayed quiet for a moment, so it follows the user's action instead of landing on top of it.
package enum DemoPhoneFinaleGate {
    package enum Decision: Equatable, Sendable {
        case present
        case wait
        case drop
    }

    package struct Screen: Equatable, Sendable {
        package var appIsActive: Bool
        package var hasModal: Bool
        package var inTransition: Bool

        package init(appIsActive: Bool, hasModal: Bool, inTransition: Bool) {
            self.appIsActive = appIsActive
            self.hasModal = hasModal
            self.inTransition = inTransition
        }

        package var isQuiet: Bool { appIsActive && !hasModal && !inTransition }
    }

    /// How many quiet checks in a row open the finale.
    package static let quietChecksNeeded = 2

    package static func decision(demoIsActive: Bool, screen: Screen, quietChecks: Int) -> Decision {
        guard demoIsActive else { return .drop }
        guard screen.isQuiet else { return .wait }
        return quietChecks + 1 >= quietChecksNeeded ? .present : .wait
    }

    /// The quiet streak after one more check.
    package static func quietChecks(after screen: Screen, previous: Int) -> Int {
        screen.isQuiet ? previous + 1 : 0
    }
}
