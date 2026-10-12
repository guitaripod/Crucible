import CrucibleCore
@preconcurrency import UIKit

/// Shows the paywall for `ProAccess.requestUnlock` from whatever is on top, so every locked control opens it the same way
/// whether it lives on a tab, in a pushed screen or in another sheet.
@MainActor
enum PaywallPresenter {
    static func install(on access: ProAccess = .shared) {
        access.paywallPresenter = { request, completion in
            present(request, completion: completion)
        }
    }

    /// Shows the offer itself, for the places that exist to show it. `requestUnlock` returns at once when the demo has everything
    /// unlocked, so these ask the sheet directly and the offer stays one tap away during the demo.
    static func showOffer(from presenter: UIViewController, feature: ProFeature? = nil) {
        var top = presenter
        while let presented = top.presentedViewController { top = presented }
        guard !(top is PaywallViewController) else { return }
        AppLogger.notice("Paywall shown from \(type(of: presenter)) on request", .store)
        PaywallViewController.present(PaywallRequest(feature: feature), from: top) { _ in }
    }

    private static func present(_ request: PaywallRequest, completion: @escaping @MainActor (Bool) -> Void) {
        guard let top = topMostViewController(), !(top is PaywallViewController) else {
            AppLogger.info("Paywall request ignored: no screen to show it or one is already open", .store)
            completion(false)
            return
        }
        AppLogger.notice("Paywall shown for \(request.feature?.rawValue ?? "no feature")", .store)
        PaywallViewController.present(request, from: top, completion: completion)
    }

    /// The end of the presented chain of the active window: a sheet over a sheet over a tab.
    private static func topMostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first else { return nil }
        var top = window.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        while let current = top, current.isBeingDismissed, let presenting = current.presentingViewController {
            top = presenting
        }
        return top
    }
}
