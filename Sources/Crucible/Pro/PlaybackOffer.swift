import CrucibleCore
import MidgarCore
import UIKit

extension PlaybackOffer {
    /// Counts a finished item and, a moment after the player has closed, shows over `host` what it led to: the Pro Week's
    /// announcement on the first, the paywall saying the week has ended on the first after it, or the paywall when the offer
    /// policy says it is the moment. A note that could not be shown stays due for the next finish.
    static func offerAfterFinishing(over host: UIViewController?) {
        guard let host else { return }
        let outcome = noteFinishedItem()
        guard outcome != .nothing else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard host.presentedViewController == nil, host.view.window != nil else { return }
            show(outcome, over: host)
        }
    }

    private static func show(_ outcome: Outcome, over host: UIViewController) {
        let access = ProAccess.shared
        switch outcome {
        case .nothing:
            break
        case .proWeekStarted:
            guard let endsAt = access.proWeekEndsAt else { return }
            access.markProWeekAnnounced()
            MidgarLog.info("Pro Week announced after a finished item", category: .store)
            host.present(ProWeekStartViewController(endsAt: endsAt), animated: true)
        case .proWeekEnded:
            access.markProWeekEndNoticeShown()
            recordOffer()
            MidgarLog.info("Pro Week end shown after a finished item", category: .store)
            PaywallPresenter.showOffer(from: host, followsProWeek: true)
        case .offer:
            recordOffer()
            MidgarLog.info("Pro offered after a finished item", category: .store)
            PaywallPresenter.showOffer(from: host)
        }
    }
}
