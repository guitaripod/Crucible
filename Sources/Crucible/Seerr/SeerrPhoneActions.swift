import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Seerr's entries in menus on the iPhone and iPad.
@MainActor
enum SeerrPhoneActions {
    /// Request More Seasons for a show on the server that Seerr says is missing seasons nobody asked for yet; nil otherwise.
    static func requestMoreSeasons(for show: PlexMetadata, api: APIClient, host: UIViewController?) async -> UIAction? {
        guard SeerrAccount.shared.isConnected,
              let state = try? await SeerrTitles.shared.state(for: show, api: api),
              state.canRequest(with: SeerrAccount.shared.permissions) else { return nil }
        return UIAction(title: SeerrCopy.requestMore, image: UIImage(systemName: "plus.rectangle.on.rectangle")) { [weak host] _ in
            SeerrRequestViewController.present(for: show, api: api, isOnServer: true, from: host)
        }
    }
}
