import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Rating a title the viewer was asked about, from the Rate What You Watched row or a reminder: the half-star sheet, the save
/// behind it, and the long-press menu. `picked` tells the screen to drop the card at once, and again with false when the
/// server refused the rating, so the card comes back.
@MainActor
enum RateAskActions {
    static func posterConfiguration(for ask: RatingAsk, now: Date = Date()) -> PosterContentConfiguration {
        var config = PosterContentConfiguration()
        config.title = ask.title
        config.subtitle = ask.caption(now: now)
        config.posterPath = ask.posterPath
        config.placeholderIcon = ask.isShow ? "tv" : "film"
        return config
    }

    static func rate(_ ask: RatingAsk, api: APIClient, from host: UIViewController, source: UIView, picked: @escaping @MainActor (Bool) -> Void) {
        RatingViewController.present(from: host, source: source, title: RatingAskCopy.question(for: ask), rating: nil) { rating in
            guard let rating else { return }
            save(rating, for: ask, api: api, picked: picked)
        }
    }

    static func save(_ rating: UserRating, for ask: RatingAsk, api: APIClient, picked: @escaping @MainActor (Bool) -> Void) {
        picked(true)
        Task { @MainActor in
            do {
                try await RatingService.setRating(rating, ratingKey: ask.ratingKey, api: api)
                Haptics.success()
            } catch {
                Haptics.error()
                picked(false)
            }
        }
    }

    static func menu(
        for ask: RatingAsk,
        api: APIClient,
        navigation: @escaping @MainActor () -> UINavigationController?,
        rate: @escaping @MainActor () -> Void
    ) -> UIMenu {
        UIMenu(children: [
            UIAction(title: UserRatingCopy.rate, image: UIImage(systemName: "star")) { _ in rate() },
            UIAction(title: String(localized: "View Details"), image: UIImage(systemName: "info.circle")) { _ in
                openDetail(ask, api: api, from: navigation())
            },
            UIAction(title: WatchCardScreens.title, image: UIImage(systemName: WatchCardScreens.symbol)) { _ in
                guard let host = navigation() else { return }
                WatchCardScreens.present(WatchCardOrigin(ask: ask), api: api, from: host)
            },
            UIAction(title: RatingAskCopy.notNow, image: UIImage(systemName: "xmark.circle")) { _ in
                Haptics.light()
                FinishedTitlesLedger.shared.dismiss(ask.ratingKey)
            },
        ])
    }

    static func openDetail(_ ask: RatingAsk, api: APIClient, from navigation: UINavigationController?) {
        let destination: UIViewController = ask.isShow
            ? ShowDetailViewController(api: api, showRatingKey: ask.ratingKey)
            : MediaDetailViewController(api: api, ratingKey: ask.ratingKey, mediaType: ask.mediaType)
        navigation?.pushViewController(destination, animated: true)
    }
}
