import AVKit
import CrucibleCore
import CrucibleDesign
import CrucibleMedia
import UIKit

extension TVPlayerCoordinator {
    /// Looks up the next episode ahead of time and hands it to the player as a content proposal that
    /// the system presents, as our Up Next card, when the credits begin or at the end of an item
    /// without credits.
    func prepareUpNext(for session: PlaybackSession) {
        upNextTask?.cancel()
        upNextTask = Task { [weak self] in
            guard let offer = await session.nextEpisodeOffer(), !Task.isCancelled else { return }
            let preview = await Self.loadPreview(for: offer.episode)
            guard let self, !Task.isCancelled, session === self.session else { return }
            AppLogger.notice("Up Next prepared: \(offer.episode.id) credits=\(String(describing: session.creditsStartSecs)) offset=\(session.streamOffset)", .playback)
            upNextOffer = offer
            upNextPreview = preview
            playerVC.contentProposalViewController = TVUpNextViewController(offer: offer, preview: preview)
            session.player?.currentItem?.nextContentProposal = makeProposal()
        }
    }

    private static func loadPreview(for episode: PlexMetadata) async -> UIImage? {
        guard let path = episode.thumb ?? episode.grandparentThumb else { return nil }
        return await ImageLoader.shared.loadBackdrop(path: path, width: 640)
    }

    func makeProposal() -> AVContentProposal? {
        guard let offer = upNextOffer, let session else { return nil }
        let transition = session.creditsStartSecs.map {
            CMTime(seconds: max(0, $0 - session.streamOffset), preferredTimescale: 600)
        } ?? .indefinite
        let proposal = AVContentProposal(
            contentTimeForTransition: transition,
            title: Self.title(of: offer.episode),
            previewImage: upNextPreview
        )
        proposal.automaticAcceptanceInterval = .nan
        return proposal
    }

    private static func title(of episode: PlexMetadata) -> String {
        [Formatters.episodeCode(episode.parentIndex, episode.index), episode.title].compactMap { $0 }.joined(separator: " · ")
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        shouldPresent proposal: AVContentProposal
    ) -> Bool {
        guard !isFinishing else { return false }
        AppLogger.notice("Up Next proposal presented for ratingKey=\(request.ratingKey)", .playback)
        session?.setUpNextVisible(true)
        clearContextualActions()
        return true
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        didAccept proposal: AVContentProposal
    ) {
        guard let offer = upNextOffer else { return }
        advance(to: offer)
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        didReject proposal: AVContentProposal
    ) {
        Task { await finish(dismiss: false) }
    }
}
