import CrucibleCore
import MidgarCore
import UIKit

extension TVAppCoordinator {
    private static let finaleSettleDelay: Duration = .milliseconds(1200)
    private static let finaleRetryInterval: Duration = .milliseconds(800)

    /// Lets the tour ask for the finale once enough of it is done; the screen appears when nothing else is in the way.
    func installDemo() {
        DemoTour.shared.onFinale = { [weak self] in self?.scheduleFinale() }
    }

    func removeDemo() {
        finaleTask?.cancel()
        finaleTask = nil
        DemoTour.shared.onFinale = nil
    }

    /// Shows the demo's welcome once, over the main UI, the first time a demo session reaches it.
    func presentDemoIntroIfPending() {
        guard DemoMode.shared.isActive, TVDemoState.isIntroPending, let tabBar = unobstructedTabBar else { return }
        TVDemoState.clearIntro()
        tabBar.present(TVDemoIntroViewController(), animated: TVMotion.animationsEnabled)
    }

    /// The finale never covers the player, an alert, the paywall or any other presented screen: it waits, a little after the step that
    /// earned it, until the main UI is free, and gives up if the demo ends first.
    private func scheduleFinale() {
        guard !ProAccess.shared.isPro else {
            MidgarLog.notice("Demo finale skipped: Pro is already owned", category: .lifecycle)
            return
        }
        MidgarLog.notice("Demo finale scheduled", category: .lifecycle)
        finaleTask?.cancel()
        finaleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.finaleSettleDelay)
            while !Task.isCancelled, let self, DemoMode.shared.isActive {
                if let tabBar = unobstructedTabBar {
                    MidgarLog.notice("Demo finale presented", category: .lifecycle)
                    presentFinale(over: tabBar)
                    return
                }
                try? await Task.sleep(for: Self.finaleRetryInterval)
            }
        }
    }

    private func presentFinale(over tabBar: TVRootTabBarController) {
        let finale = TVDemoFinaleViewController(offersPro: ProAccess.shared.isStoreBacked) { [weak self] in
            self?.leaveDemo()
        }
        tabBar.present(finale, animated: TVMotion.animationsEnabled)
    }

    /// The main UI with nothing presented over it and nothing on its way in or out.
    private var unobstructedTabBar: TVRootTabBarController? {
        guard let tabBar = window.rootViewController as? TVRootTabBarController,
              tabBar.presentedViewController == nil,
              !tabBar.isBeingPresented, !tabBar.isBeingDismissed
        else { return nil }
        return tabBar
    }
}
