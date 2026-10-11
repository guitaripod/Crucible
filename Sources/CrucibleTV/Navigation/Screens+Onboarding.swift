import CrucibleCore
import UIKit

extension TVScreens {
    static func onboarding(
        mode: TVOnboardingMode,
        onConnected: @escaping @MainActor (PlexConnection) -> Void
    ) -> UIViewController {
        TVOnboardingFlow(mode: mode, onConnected: onConnected).makeRoot()
    }
}
