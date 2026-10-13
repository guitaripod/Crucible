import CrucibleCore
import Foundation

/// What the Apple TV remembers about the demo beyond `DemoMode` and `DemoTour`: whether the welcome screen of the demo still has to be
/// shown. It is set when the demo starts and cleared when that screen appears, so a demo that resumes after a relaunch never repeats it.
enum TVDemoState {
    private static let introPendingKey = "crucible_tv_demo_intro_pending"

    static var isIntroPending: Bool {
        UserDefaults.standard.bool(forKey: introPendingKey)
    }

    static func markIntroPending() {
        UserDefaults.standard.set(true, forKey: introPendingKey)
    }

    static func clearIntro() {
        UserDefaults.standard.removeObject(forKey: introPendingKey)
    }

    /// "2 of 4 done", the progress line of the You row, the tour screen and its accessibility value.
    @MainActor
    static func progressText(for tour: DemoTour = .shared) -> String {
        "\(tour.completedCount) of \(tour.steps.count) done"
    }
}
