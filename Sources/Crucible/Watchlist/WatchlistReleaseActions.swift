import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// A show from the watchlist with something new out that the server does not have: its card, what a tap does and its menu.
@MainActor
enum WatchlistReleaseActions {
    static func posterConfiguration(for release: WatchlistRelease, now: Date = Date()) -> PosterContentConfiguration {
        var config = PosterContentConfiguration()
        config.title = release.title
        config.subtitle = release.caption(now: now)
        config.posterPath = release.posterPath
        config.placeholderIcon = "tv"
        config.badgeText = release.news.badge
        return config
    }

    /// The request sheet, which asks Seerr for the new season, or says how to connect Seerr when it is not.
    static func open(_ release: WatchlistRelease, api: APIClient, from host: UIViewController) {
        Haptics.selection()
        SeerrRequestViewController.present(for: release.asMetadata, api: api, isOnServer: false, from: host)
    }

    static func menu(for release: WatchlistRelease, api: APIClient, host: UIViewController) -> UIMenu {
        let entry = release.asMetadata
        var actions: [UIMenuElement] = []
        if SeerrAccount.shared.isConnected {
            actions.append(UIAction(title: SeerrCopy.request, image: UIImage(systemName: "plus.circle")) { [weak host] _ in
                guard let host else { return }
                open(release, api: api, from: host)
            })
        }
        if let remove = WatchlistScreen.toggleAction(for: entry, isListed: true, api: api, host: host) {
            remove.attributes = .destructive
            actions.append(remove)
        }
        return UIMenu(title: release.title, children: actions)
    }
}
