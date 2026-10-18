import CrucibleCore
import CrucibleStats
import UIKit

extension TVAppCoordinator {
    /// Watches for the two moments Crucible Pro speaks up: the end of the first finished playback and the last days of a free trial.
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

    /// A trial about to end outranks the first-finish note, so only one of them speaks after a playback.
    private func playbackEnded(finishedAnItem: Bool) {
        Task {
            if await presentTrialNoticeIfDue() { return }
            if finishedAnItem { presentFirstFinishIfDue() }
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

    private func presentFirstFinishIfDue() {
        let moment = ProTVMoments.firstFinish(
            status: ProAccess.shared.status,
            isStoreBacked: ProAccess.shared.isStoreBacked,
            isDemo: DemoMode.shared.isActive
        )
        guard let moment else { return }
        present(moment)
    }

    /// Only the main screens qualify: nothing is presented over them, so a note never lands on the player, the paywall or another
    /// alert, and never in the demo.
    private var canPresentProMoment: Bool {
        guard !DemoMode.shared.isActive, let root = window.rootViewController as? TVRootTabBarController else { return false }
        return root.presentedViewController == nil
    }

    @discardableResult
    private func present(_ moment: ProMoment) -> Bool {
        let ledger = ProMomentLedger()
        guard canPresentProMoment, !ledger.hasShown(moment.kind), let presenter = topViewController else { return false }
        ledger.markShown(moment.kind)
        let alert = UIAlertController(title: moment.title, message: moment.message, preferredStyle: .alert)
        let action = UIAlertAction(title: moment.actionTitle, style: .default) { [weak self] _ in self?.perform(moment.action) }
        alert.addAction(action)
        if moment.action != .acknowledge {
            alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        }
        alert.preferredAction = action
        presenter.present(alert, animated: true)
        AppLogger.notice("Pro moment shown: \(moment.kind)", .store)
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
