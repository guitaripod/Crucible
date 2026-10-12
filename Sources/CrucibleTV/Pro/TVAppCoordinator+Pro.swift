import CrucibleCore
import UIKit

extension TVAppCoordinator {
    /// Starts Crucible Pro for this launch and lets any screen ask for the paywall through `ProAccess.requestUnlock`. The paywall
    /// covers whatever is on screen, the tab bar included; playback never asks for it.
    func installPro() {
        ProAccess.shared.configureForLaunch(store: nil)
        ProAccess.shared.paywallPresenter = { [weak self] request, completion in
            guard let self else {
                completion(false)
                return
            }
            presentPaywall(request, completion: completion)
        }
    }

    func removePro() {
        ProAccess.shared.paywallPresenter = nil
    }

    /// A second request while the paywall is up, or while its host is being dismissed, is answered with "no" instead of stacking.
    private func presentPaywall(_ request: PaywallRequest, completion: @escaping @MainActor (Bool) -> Void) {
        guard let presenter = topViewController, !(presenter is TVPaywallViewController), !presenter.isBeingDismissed else {
            completion(false)
            return
        }
        TVPaywallViewController.present(request, from: presenter, completion: completion)
    }
}
