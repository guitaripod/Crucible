import CrucibleCore
import MidgarCore
import UIKit

extension TVPlayerCoordinator {
    /// Once nothing plays next, titles like the one that ended take the screen over the player's last frame; without any the
    /// player closes, as it always has.
    func offerWhatsNext() {
        guard postPlayTask == nil, postPlay == nil, !isFinishing, !isAdvancing else { return }
        let ended = request
        postPlayTask = Task { [weak self] in
            guard let self else { return }
            let suggestions = await PostPlay.suggestions(for: ended, api: api)
            guard !Task.isCancelled else { return }
            postPlayTask = nil
            guard !isFinishing, !isAdvancing, ended.ratingKey == request.ratingKey else { return }
            guard !suggestions.isEmpty, playerVC.presentingViewController != nil else {
                await finish(animated: true)
                return
            }
            presentPostPlay(suggestions, after: ended)
        }
    }

    private func presentPostPlay(_ suggestions: [PlexMetadata], after ended: PlaybackRequest) {
        clearContextualActions()
        let screen = TVPostPlayViewController(heading: PostPlay.heading(for: ended), items: suggestions)
        screen.onPick = { [weak self] item in self?.playSuggestion(item) }
        screen.onClose = { [weak self] in
            Task { await self?.finish(animated: true) }
        }
        postPlay = screen
        topmost(from: playerVC).present(screen, animated: TVMotion.animationsEnabled)
        MidgarLog.notice("Post-play offered \(suggestions.count) titles after ratingKey=\(ended.ratingKey)", category: .playback)
    }

    /// A movie plays in this player behind the pre-roll, as the next episode would; a show opens its screen once the player
    /// has closed.
    private func playSuggestion(_ item: PlexMetadata) {
        guard !isFinishing, !isAdvancing else { return }
        viewerActed()
        let screen = postPlay
        postPlay = nil
        guard item.mediaType == "movie" else {
            if let presenter = rootPresenter, let openTitle {
                afterDismiss = { openTitle(.related(item), presenter) }
            }
            Task { await finish(animated: true) }
            return
        }
        unattendedEpisodes = 0
        viewerActedThisEpisode = true
        isAdvancing = true
        request = PlaybackRequest(item: item)
        MidgarLog.notice("Post-play picked ratingKey=\(item.id)", category: .playback)
        guard let screen, screen.presentingViewController != nil else {
            restartSession()
            return
        }
        screen.dismiss(animated: false) { [weak self] in self?.restartSession() }
    }
}
