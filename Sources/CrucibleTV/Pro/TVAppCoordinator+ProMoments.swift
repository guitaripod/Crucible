import CrucibleCore
import CrucibleStats
import MidgarCore
import UIKit

extension TVAppCoordinator {
    /// Watches for the moments Crucible Pro speaks up: the end of a finished playback, which also begins and ends the Pro Week, and
    /// the last days of a free trial.
    func installProMoments() {
        TVPlayerCoordinator.onEnded = { [weak self] finishedAnItem in
            self?.playbackEnded(finishedAnItem: finishedAnItem)
        }
        proMomentObserver = ProAccess.shared.observe { [weak self] _ in
            Task { await self?.presentTrialNoticeIfDue() }
        }
    }

    func removeProMoments() {
        TVPlayerCoordinator.onEnded = nil
        if let proMomentObserver { ProAccess.shared.stopObserving(proMomentObserver) }
        proMomentObserver = nil
    }

    /// A trial about to end outranks the finish note, so only one of them speaks after a playback.
    private func playbackEnded(finishedAnItem: Bool) {
        Task {
            if await presentTrialNoticeIfDue() { return }
            if finishedAnItem { presentFinishMomentIfDue() }
        }
    }

    /// Shows the trial note when a trial ends within two days and the viewer has not seen it for that end date. Reports whether it
    /// was shown.
    @discardableResult
    func presentTrialNoticeIfDue() async -> Bool {
        guard canPresentProMoment, ProAccess.shared.status.entitlement?.isTrial == true else { return false }
        let week = await StatsManager.shared.store?.homeWeekSummaryOrNil()
        guard let moment = ProTVMoments.trialEnding(status: ProAccess.shared.status, weekWatchSeconds: week?.thisWeekSeconds) else { return false }
        return present(moment)
    }

    /// A trial viewer hears once what the trial unlocked. Everyone else's finish counts: a free viewer's first one begins the Pro
    /// Week and says so, the first after the week says it has ended, and otherwise, when the offer policy says so, a free viewer
    /// is told what Pro adds, then not again until the policy's next turn.
    private func presentFinishMomentIfDue() {
        let access = ProAccess.shared
        let status = access.status
        let moment = ProTVMoments.firstFinish(status: status, isStoreBacked: access.isStoreBacked, isDemo: DemoMode.shared.isActive)
        if status.entitlement?.isTrial == true {
            if let moment { present(moment) }
            return
        }
        switch PlaybackOffer.noteFinishedItem() {
        case .nothing:
            break
        case .proWeekStarted:
            guard let endsAt = access.proWeekEndsAt, show(ProTVMoments.proWeekStarted(endsAt: endsAt)) else { return }
            access.markProWeekAnnounced()
        case .proWeekEnded:
            guard show(ProTVMoments.proWeekEnded()) else { return }
            access.markProWeekEndNoticeShown()
            PlaybackOffer.recordOffer()
        case .offer:
            guard let moment, show(moment) else { return }
            PlaybackOffer.recordOffer()
        }
    }

    /// Only the main screens qualify: nothing is presented over them, so a note never lands on the player, the paywall or another
    /// alert, and never in the demo unless it previews the free version.
    private var canPresentProMoment: Bool {
        guard !DemoMode.shared.isActive || DemoMode.shared.previewsFreeVersion,
              let root = window.rootViewController as? TVRootTabBarController else { return false }
        return root.presentedViewController == nil
    }

    /// Shows a moment that appears once, and remembers it.
    @discardableResult
    private func present(_ moment: ProMoment) -> Bool {
        let ledger = ProMomentLedger()
        guard !ledger.hasShown(moment.kind), show(moment) else { return false }
        ledger.markShown(moment.kind)
        return true
    }

    private func show(_ moment: ProMoment) -> Bool {
        guard canPresentProMoment, let presenter = topViewController else { return false }
        let alert = UIAlertController(title: moment.title, message: moment.message, preferredStyle: .alert)
        let action = UIAlertAction(title: moment.actionTitle, style: .default) { [weak self] _ in self?.perform(moment.action) }
        alert.addAction(action)
        if moment.action != .acknowledge {
            alert.addAction(UIAlertAction(title: String(localized: "Not Now"), style: .cancel))
        }
        alert.preferredAction = action
        presenter.present(alert, animated: true)
        MidgarLog.notice("Pro moment shown: \(moment.kind)", category: .store)
        return true
    }

    private func perform(_ action: ProMoment.Action) {
        switch action {
        case .openStatistics: router.showStatistics()
        case .seePro: ProAccess.shared.requestUnlock(nil)
        case .acknowledge: break
        }
    }
}
