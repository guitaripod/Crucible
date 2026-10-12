import Foundation

/// What the iPhone remembers about the running demo besides the Core state: whether the welcome sheet is still owed. It is owed once
/// per demo session, from the moment the demo starts until the sheet has been shown.
@MainActor
package final class DemoPhoneSession {
    package static let shared = DemoPhoneSession()

    private static let introPendingKey = "crucible_demo_phone_intro_pending"

    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    package var introIsPending: Bool { defaults.bool(forKey: Self.introPendingKey) }

    package func beginSession() {
        defaults.set(true, forKey: Self.introPendingKey)
    }

    package func introWasShown() {
        defaults.set(false, forKey: Self.introPendingKey)
    }

    package func endSession() {
        defaults.removeObject(forKey: Self.introPendingKey)
    }
}
