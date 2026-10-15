import CoreSpotlight
import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Runs the iPhone side of the demo that no single screen owns: the welcome sheet after the first entry, the tour's "Show me" jumps,
/// the soft paywall that waits for a quiet screen, and leaving the demo.
@MainActor
final class DemoCoordinator {
    static let shared = DemoCoordinator()

    private static let finalePollInterval: Duration = .milliseconds(750)

    private weak var tabBar: TabBarController?
    private var finaleTask: Task<Void, Never>?
    private var keyboardIsUp = false
    private var keyboardObservers: [NSObjectProtocol] = []

    func install() {
        DemoTour.shared.onFinale = { [weak self] in self?.finaleIsDue() }
        trackKeyboard()
    }

    /// The finale waits while the keyboard is up, so it never lands on a search the user is still typing.
    private func trackKeyboard() {
        guard keyboardObservers.isEmpty else { return }
        let center = NotificationCenter.default
        keyboardObservers = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardIsUp = true }
            },
            center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardIsUp = false }
            },
        ]
    }

    /// The main screen is up: the demo's welcome sheet is shown now if it is still owed.
    func mainAppDidAppear(_ tabBar: TabBarController) {
        self.tabBar = tabBar
        guard DemoMode.shared.isActive, DemoPhoneSession.shared.introIsPending, tabBar.presentedViewController == nil else { return }
        DemoPhoneSession.shared.introWasShown()
        tabBar.present(DemoIntroViewController(), animated: true)
    }

    // MARK: - Show me

    /// Takes the user to where `step` happens and starts it where that takes no more than a tap.
    func show(_ step: DemoTourStep) {
        guard let tabBar, tabBar.presentedViewController == nil else { return }
        switch step {
        case .play: playHighlightedTitle(in: tabBar)
        case .browse: tabBar.open(.library)
        case .search: searchForSample(in: tabBar)
        case .statistics: openStatistics(in: tabBar, showingPoster: false)
        case .poster: openStatistics(in: tabBar, showingPoster: true)
        case .download: downloadSuggestedTitle(in: tabBar)
        }
    }

    private func playHighlightedTitle(in tabBar: TabBarController) {
        tabBar.open(.home)
        tabBar.homeScreen?.playHighlightedTitle()
    }

    private func searchForSample(in tabBar: TabBarController) {
        let navigation = tabBar.open(.search)
        guard let query = DemoPhoneSearchSample.query(fromTitles: tabBar.homeScreen?.sampleTitles ?? []),
              let search = navigation?.topViewController as? SearchViewController else { return }
        search.run(sample: query)
    }

    private func openStatistics(in tabBar: TabBarController, showingPoster: Bool) {
        let navigation = tabBar.open(.you)
        let statistics = StatisticsViewController(api: tabBar.api)
        statistics.opensPosterWhenLoaded = showingPoster
        navigation?.pushViewController(statistics, animated: true)
    }

    private func downloadSuggestedTitle(in tabBar: TabBarController) {
        if let title = tabBar.homeScreen?.downloadCandidate {
            DownloadManager.shared.requestDownload(metadata: title)
        }
        tabBar.open(.downloads)
    }

    // MARK: - Soft paywall

    private func finaleIsDue() {
        finaleTask?.cancel()
        finaleTask = Task { [weak self] in
            var quietChecks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.finalePollInterval)
                guard let self, !Task.isCancelled else { return }
                let screen = currentScreen()
                switch DemoPhoneFinaleGate.decision(demoIsActive: DemoMode.shared.isActive, screen: screen, quietChecks: quietChecks) {
                case .drop:
                    return
                case .present:
                    presentFinale()
                    return
                case .wait:
                    quietChecks = DemoPhoneFinaleGate.quietChecks(after: screen, previous: quietChecks)
                }
            }
        }
    }

    private func currentScreen() -> DemoPhoneFinaleGate.Screen {
        guard let tabBar else { return .init(appIsActive: false, hasModal: true, inTransition: false, keyboardIsUp: keyboardIsUp) }
        let navigation = tabBar.selectedViewController as? UINavigationController
        return .init(
            appIsActive: UIApplication.shared.applicationState == .active,
            hasModal: tabBar.presentedViewController != nil,
            inTransition: tabBar.transitionCoordinator != nil || navigation?.transitionCoordinator != nil,
            keyboardIsUp: keyboardIsUp
        )
    }

    private func presentFinale() {
        guard let tabBar else { return }
        AppLogger.notice("Demo finale shown", .ui)
        let sheet = DemoFinaleViewController()
        sheet.onConnect = { [weak self, weak sheet] in
            guard let sheet else { return }
            self?.confirmLeaving(from: sheet)
        }
        tabBar.present(sheet, animated: true)
    }

    // MARK: - Leaving

    func confirmLeaving(from presenter: UIViewController) {
        let alert = UIAlertController(title: DemoPhoneCopy.leaveConfirmTitle, message: DemoPhoneCopy.leaveConfirmMessage, preferredStyle: .alert)
        let scene = presenter.view.window?.windowScene?.delegate as? SceneDelegate
        alert.addAction(UIAlertAction(title: DemoPhoneCopy.leaveTitle, style: .destructive) { [weak self] _ in
            self?.leave(scene: scene)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presenter.present(alert, animated: true)
    }

    /// Ends the demo like a sign-out and brings the welcome screen back.
    func leave(scene: SceneDelegate?) {
        Task { [weak self] in
            self?.finaleTask?.cancel()
            await DemoMode.shared.exit(.phone)
            self?.forgetWhatTheDemoLeftBehind()
            scene?.reconfigureRoot()
        }
    }

    /// The demo donates nothing to Spotlight, Handoff or Siri, so this only makes sure that stays true after it ends, and that the
    /// fictional library's per-show settings do not carry over to a real server.
    private func forgetWhatTheDemoLeftBehind() {
        DemoPhoneSession.shared.endSession()
        AutoDownloadPolicy.forgetAll()
        NSUserActivity.deleteAllSavedUserActivities {}
        CSSearchableIndex.default().deleteAllSearchableItems { _ in }
    }
}
