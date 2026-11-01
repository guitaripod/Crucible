import CrucibleCore
import MidgarCore
import UIKit

/// When a film or episode watched to the end offers Crucible Pro. The app's entry installs `noteValue` and
/// `noteOffered` from MidgarKit's offer policy (decision D22: after the third finish, then every fifth, at least three
/// days apart, three times in all); until then, as in tests and previews, nothing is offered.
@MainActor
enum PlaybackOffer {
    static var noteValue: (_ isOwned: Bool) -> Bool = { _ in false }
    static var noteOffered: () -> Void = {}

    /// Counts a finished item and offers Pro over `host` a moment after the player has closed, when the policy says
    /// it is the moment. An install in the demo, or one that owns Pro, is counted as owning it.
    static func offerAfterFinishing(over host: UIViewController?) {
        guard let host, noteValue(ProAccess.shared.hasFullAccess) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard host.presentedViewController == nil, host.view.window != nil else { return }
            noteOffered()
            MidgarLog.info("Pro offered after a finished item", category: .store)
            PaywallPresenter.showOffer(from: host)
        }
    }
}
