import CrucibleCore
import CrucibleStats
@preconcurrency import UIKit

extension StatsDestination {
    @MainActor
    func makeViewController(api: APIClient) -> UIViewController {
        switch self {
        case .movie(let ratingKey):
            return MediaDetailViewController(api: api, ratingKey: ratingKey, mediaType: "movie")
        case .episode(let ratingKey, let showRatingKey):
            return MediaDetailViewController(api: api, ratingKey: ratingKey, mediaType: "episode", showRatingKey: showRatingKey)
        case .show(let ratingKey):
            return ShowDetailViewController(api: api, showRatingKey: ratingKey)
        }
    }
}
