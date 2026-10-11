import CrucibleCore
@preconcurrency import UIKit

extension LibraryPoster {
    var configuration: PosterContentConfiguration {
        var config = PosterContentConfiguration()
        config.posterPath = posterPath
        config.title = title
        config.subtitle = subtitle
        config.placeholderIcon = placeholderIcon
        config.progress = progress
        config.isUnwatched = isUnwatched
        config.unwatchedCount = unwatchedCount
        return config
    }
}

extension LibraryDestination {
    @MainActor
    func viewController(api: APIClient) -> UIViewController {
        switch self {
        case .show(let ratingKey):
            return ShowDetailViewController(api: api, showRatingKey: ratingKey)
        case .media(let item):
            return MediaDetailViewController(
                api: api,
                ratingKey: item.id,
                mediaType: item.mediaType,
                showRatingKey: item.grandparentRatingKey,
                seasonRatingKey: item.parentRatingKey
            )
        }
    }
}

extension LibraryItemAction {
    @MainActor
    func menuAction(perform: @escaping @MainActor () -> Void) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: symbol)) { _ in
            perform()
        }
    }
}
