import CrucibleCore
import MidgarCore
import UIKit

extension PlaybackOffer {
    /// Counts a finished item and offers Pro over `host` a moment after the player has closed, when the policy says it is the
    /// moment.
    static func offerAfterFinishing(over host: UIViewController?) {
        guard let host, noteFinishedItem() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard host.presentedViewController == nil, host.view.window != nil else { return }
            noteOffered()
            MidgarLog.info("Pro offered after a finished item", category: .store)
            PaywallPresenter.showOffer(from: host)
        }
    }
}
