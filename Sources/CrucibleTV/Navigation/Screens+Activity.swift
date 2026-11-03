import CrucibleCore
import UIKit

extension TVScreens {
    static func serverActivity(_ env: TVAppEnvironment) -> UIViewController {
        let grid = TVMediaGridViewController(
            title: ServerActivity.title,
            empty: .init(symbol: "dot.radiowaves.left.and.right", title: ServerActivity.emptyTitle, message: ServerActivity.emptyText),
            card: { session in
                let card = DetailRelatedCard(item: session)
                return TVCardItem(
                    id: session.entryID,
                    artworkPath: card.posterPath,
                    title: session.mediaType == "episode" ? (session.grandparentTitle ?? session.title) : session.title,
                    subtitle: ServerActivity.subtitle(session),
                    progress: card.progress,
                    placeholderSymbol: card.isShow || session.mediaType == "episode" ? "tv" : "film"
                )
            },
            load: { try await ServerActivity.sessions(api: env.api) }
        )
        grid.refreshInterval = .seconds(10)
        grid.summary = { items in items.count == 1 ? String(localized: "1 stream") : String(localized: "\(items.count) streams") }
        installTitleActions(on: grid, env: env)
        return grid
    }
}
