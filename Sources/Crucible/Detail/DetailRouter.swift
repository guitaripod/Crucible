import CrucibleCore
import UIKit

/// Builds the screen a `DetailRoute` leads to.
@MainActor
enum DetailRouter {
    static func viewController(for route: DetailRoute, api: APIClient) -> UIViewController {
        switch route {
        case .show(let ratingKey, let initialSeasonKey):
            return ShowDetailViewController(api: api, showRatingKey: ratingKey, initialSeasonKey: initialSeasonKey)
        case .item(let ratingKey, let mediaType, let showRatingKey, let seasonRatingKey):
            return MediaDetailViewController(
                api: api,
                ratingKey: ratingKey,
                mediaType: mediaType,
                showRatingKey: showRatingKey,
                seasonRatingKey: seasonRatingKey
            )
        }
    }
}
