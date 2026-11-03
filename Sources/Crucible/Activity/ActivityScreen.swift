import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// What is playing on the server right now, refreshed while the screen is open.
@MainActor
enum ActivityScreen {
    static func serverActivity(api: APIClient) -> MediaGridViewController {
        let grid = MediaGridViewController(
            title: ServerActivity.title,
            empty: .init(symbol: "dot.radiowaves.left.and.right", title: ServerActivity.emptyTitle, text: ServerActivity.emptyText)
        ) {
            try await ServerActivity.sessions(api: api)
        }
        grid.refreshInterval = .seconds(10)
        grid.configuration = { session in
            let card = DetailRelatedCard(item: session)
            return PosterContentConfiguration(
                posterPath: card.posterPath,
                title: session.mediaType == "episode" ? (session.grandparentTitle ?? session.title) : session.title,
                subtitle: ServerActivity.subtitle(session),
                progress: card.progress,
                placeholderIcon: card.isShow || session.mediaType == "episode" ? "tv" : "film"
            )
        }
        MediaGridActions.install(on: grid, api: api)
        return grid
    }
}
