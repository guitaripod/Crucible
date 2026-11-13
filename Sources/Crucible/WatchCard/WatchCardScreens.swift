import CrucibleCore
@preconcurrency import UIKit

/// Opens the watch card screen from wherever a title is: a detail page's menu, Rate What You Watched, or the end of
/// playback.
@MainActor
enum WatchCardScreens {
    static let title = String(localized: "Share Card", comment: "Menu item and button that open the screen making a shareable image of a watched movie, episode, season or show")
    static let symbol = "square.and.arrow.up.on.square"

    /// `rated` is a rating the viewer has just given that the server may not have saved yet, so the card shows it at once.
    static func present(_ origin: WatchCardOrigin, api: APIClient, from host: UIViewController, rated: (ratingKey: String, rating: UserRating)? = nil) {
        let composer = WatchCardComposerViewController(api: api, origin: origin, rated: rated)
        let navigation = UINavigationController(rootViewController: composer)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        host.present(navigation, animated: true)
    }

    /// The Share Card menu item for `origin`, or nil when there is nothing a card could be made of.
    static func action(_ origin: WatchCardOrigin?, api: APIClient, host: UIViewController) -> UIAction? {
        guard let origin, !origin.scopes.isEmpty else { return nil }
        let action = UIAction(title: title, image: UIImage(systemName: symbol)) { [weak host] _ in
            guard let host else { return }
            present(origin, api: api, from: host)
        }
        action.accessibilityIdentifier = "watchCard.open"
        return action
    }
}
