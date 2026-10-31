import AVKit
import CrucibleCore
import CrucibleDesign
import CrucibleMedia
import MidgarCore
import UIKit

extension TVPlayerCoordinator {
    /// Looks up the next episode ahead of time and hands it to the player as a content proposal that
    /// the system presents, as our Up Next card, when the credits begin or at the end of an item
    /// without credits. The card is installed as soon as the episode is known; its frame arrives
    /// whenever the image does.
    func prepareUpNext(for session: PlaybackSession) {
        upNextTask?.cancel()
        upNextTask = Task { [weak self] in
            guard let offer = await session.nextEpisodeOffer(), !Task.isCancelled else { return }
            guard let self, session === self.session else { return }
            installUpNext(offer, hasCredits: session.creditsStartSecs != nil, session: session)
            let preview = await Self.loadPreview(for: offer.episode)
            guard !Task.isCancelled, session === self.session, let preview else { return }
            showPreview(preview, on: session)
        }
    }

    private func installUpNext(_ offer: UpNextOffer, hasCredits: Bool, session: PlaybackSession) {
        MidgarLog.notice("Up Next prepared: \(offer.episode.id) credits=\(String(describing: session.creditsStartSecs)) offset=\(session.streamOffset)", category: .playback)
        upNextOffer = offer
        let card = TVUpNextViewController(offer: offer, hasCredits: hasCredits)
        card.onDeferred = { [weak self] in self?.upNextCardWasDeferred() }
        card.isAtEndOfItem = { [weak self] in self?.isItemNearEnd ?? false }
        card.asksStillWatching = { [weak self] in self?.asksStillWatching ?? false }
        upNextCard = card
        playerVC.contentProposalViewController = card
        session.player?.currentItem?.nextContentProposal = makeProposal()
    }

    private func showPreview(_ preview: UIImage, on session: PlaybackSession) {
        upNextPreview = preview
        upNextCard?.setPreview(preview)
        guard !isUpNextCardVisible else { return }
        session.player?.currentItem?.nextContentProposal = makeProposal()
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
        return AVContentProposal(
            contentTimeForTransition: transition,
            title: Self.title(of: offer.episode),
            previewImage: upNextPreview
        )
    }

    private static func title(of episode: PlexMetadata) -> String {
        [Formatters.episodeCode(episode.parentIndex, episode.index), episode.title].compactMap { $0 }.joined(separator: " · ")
    }

    private var isItemNearEnd: Bool {
        guard let item = session?.player?.currentItem else { return false }
        let duration = item.duration.seconds
        return duration.isFinite && item.currentTime().seconds >= duration - 2
    }

    private func upNextCardWasDeferred() {
        viewerActed()
        isUpNextCardVisible = false
        session?.setUpNextVisible(false)
    }

    /// The engine's own Up Next answers. The card handles the credits; the answer for the end of the
    /// item is the safety net for when no card is on screen (the viewer chose to watch the credits, or
    /// the card never came): play the next episode with autoplay, unless nobody has touched the remote for
    /// long enough that Crucible should ask first, otherwise close the player.
    func handle(_ offer: UpNextOffer) {
        switch offer.reason {
        case .requested:
            advance(to: offer, byViewer: true)
        case .credits:
            break
        case .playbackEnded:
            let ended = session
            Task { [weak self] in
                try? await Task.sleep(for: Self.upNextCardGrace)
                guard let self, ended === session, !isFinishing, !isAdvancing, !isUpNextCardVisible else { return }
                if offer.autoplays, !asksStillWatching {
                    advance(to: offer)
                } else {
                    await finish(animated: true)
                }
            }
        }
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        shouldPresent proposal: AVContentProposal
    ) -> Bool {
        guard !isFinishing else { return false }
        if let session, !session.isAtCreditsOrEnd {
            MidgarLog.notice("Up Next proposal refused before the credits ratingKey=\(request.ratingKey) position=\(Int(session.absolutePosition ?? -1)) credits=\(Int(session.creditsStartSecs ?? -1))", category: .playback)
            session.heal(reason: "Up Next proposal before the credits")
            return false
        }
        MidgarLog.notice("Up Next proposal presented for ratingKey=\(request.ratingKey) stillWatching=\(asksStillWatching) unattended=\(unattendedEpisodes)", category: .playback)
        isUpNextCardVisible = true
        session?.setUpNextVisible(true)
        clearContextualActions()
        return true
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        didAccept proposal: AVContentProposal
    ) {
        guard let offer = upNextOffer else { return }
        let byViewer = upNextCard?.acceptedByViewer ?? false
        if !byViewer, let session, !session.isAtCreditsOrEnd {
            MidgarLog.notice("Up Next countdown ended away from the credits ratingKey=\(request.ratingKey); staying on this episode", category: .playback)
            isUpNextCardVisible = false
            session.setUpNextVisible(false)
            session.player?.currentItem?.nextContentProposal = makeProposal()
            return
        }
        advance(to: offer, byViewer: byViewer)
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        didReject proposal: AVContentProposal
    ) {
        isUpNextCardVisible = false
        finishedAnItem = true
        Task { await finish(animated: false) }
    }
}
