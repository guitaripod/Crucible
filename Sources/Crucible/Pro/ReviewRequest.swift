import CrucibleCore
import MidgarCore
import StoreKit
import UIKit

/// Asks StoreKit for an App Store rating when `ReviewMoments` says a film or episode watched to the end is the moment: a beat after
/// the player has gone, and only while nothing covers the window, so it never lands on a sheet, the paywall or a Pro note. StoreKit
/// decides whether anything shows; the policy only hears that Crucible asked.
@MainActor
enum ReviewRequest {
    static let delay: Duration = .milliseconds(1_500)

    /// Guards against a second finish landing while the first ask still waits out its delay.
    private static var isPending = false

    static func ask(over host: UIViewController) {
        guard !isPending else { return }
        isPending = true
        Task { @MainActor in
            defer { isPending = false }
            try? await Task.sleep(for: delay)
            guard let scene = host.view.window?.windowScene,
                  scene.activationState == .foregroundActive,
                  host.presentedViewController == nil
            else {
                MidgarLog.info("App Store rating not asked: the window is busy", category: .store)
                return
            }
            AppStore.requestReview(in: scene)
            ReviewMoments.notePrompted()
            MidgarLog.notice("Asked for an App Store rating after a finished title", category: .store)
        }
    }
}
