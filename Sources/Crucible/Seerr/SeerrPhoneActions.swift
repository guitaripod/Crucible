import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Seerr's entries in menus on the iPhone and iPad.
@MainActor
enum SeerrPhoneActions {
    /// Request More Seasons for a show on the server that Seerr says is missing seasons nobody asked for yet; nil otherwise.
    static func requestMoreSeasons(for show: PlexMetadata, api: APIClient, host: UIViewController?) async -> UIAction? {
        await offersMoreSeasons(for: show, api: api) ? requestMoreSeasonsAction(for: show, api: api, host: host) : nil
    }

    /// Whether Seerr says `show` is missing seasons the viewer may still ask for.
    static func offersMoreSeasons(for show: PlexMetadata, api: APIClient) async -> Bool {
        guard SeerrAccount.shared.isConnected, let state = try? await SeerrTitles.shared.state(for: show, api: api) else { return false }
        return state.canRequest(with: SeerrAccount.shared.permissions)
    }

    static func requestMoreSeasonsAction(for show: PlexMetadata, api: APIClient, host: UIViewController?) -> UIAction {
        UIAction(title: SeerrCopy.requestMore, image: UIImage(systemName: "plus.rectangle.on.rectangle")) { [weak host] _ in
            SeerrRequestViewController.present(for: show, api: api, isOnServer: true, from: host)
        }
    }
}
