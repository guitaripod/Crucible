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
        MediaGridActions.install(on: grid, api: api) { [weak grid] session in
            guard let grid, let id = ServerActivity.stoppableSessionID(session) else { return [] }
            return [stopMenu(sessionID: id, api: api, host: grid)]
        }
        showDashboardButton(on: grid, api: api)
        grid.onLoaded = { [weak grid] _ in
            guard let grid else { return }
            showDashboardButton(on: grid, api: api)
        }
        return grid
    }

    /// The owner's way into the Server Dashboard. Checked on every refresh, because a fresh install learns that the
    /// account owns the server a moment after launch.
    private static func showDashboardButton(on grid: MediaGridViewController, api: APIClient) {
        guard ServerOwnership.isOwner() else {
            grid.navigationItem.rightBarButtonItem = nil
            return
        }
        guard grid.navigationItem.rightBarButtonItem == nil else { return }
        let title = String(localized: "Server Dashboard", comment: "Title of the owner's server dashboard")
        let button = UIBarButtonItem(
            image: UIImage(systemName: "gauge.with.dots.needle.33percent"),
            primaryAction: UIAction(title: title) { [weak grid] _ in
                grid?.navigationController?.pushViewController(ServerDashboardViewController(api: api), animated: true)
            }
        )
        button.accessibilityLabel = title
        grid.navigationItem.rightBarButtonItem = button
    }

    /// Stop Stream: the owner ends someone's playback and the viewer reads the reason picked.
    private static func stopMenu(sessionID: String, api: APIClient, host: MediaGridViewController) -> UIMenu {
        UIMenu(title: ManageCopy.stopStream, image: UIImage(systemName: "stop.circle"), children: ManageCopy.stopReasons.map { reason in
            UIAction(title: reason, attributes: .destructive) { [weak host] _ in
                guard let host else { return }
                ManageMenus.run(host: host) { [weak host] in
                    try await LibraryManagement.stopStream(sessionId: sessionID, reason: reason, api: api)
                    host?.reload()
                }
            }
        })
    }
}
