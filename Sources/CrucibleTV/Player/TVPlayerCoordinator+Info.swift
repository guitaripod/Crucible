import AVKit
import CrucibleCore
import CrucibleMedia
import UIKit

extension TVPlayerCoordinator {
    /// Loads the server's full record and the artwork for the info panel. The record is usually
    /// cached by the stream resolver already, so this rarely costs a request of its own.
    func loadInfo() {
        guard let display = request.metadata else { return }
        let ratingKey = request.ratingKey
        let api = self.api
        metadataTask?.cancel()
        metadataTask = Task { [weak self] in
            let detail = try? await api.requestContainer(.metadata(ratingKey: ratingKey)).Metadata?.first
            let artwork = await TVPlayerMetadata.loadArtwork(path: display.posterPath)
            guard !Task.isCancelled, let self else { return }
            infoItems = TVPlayerMetadata.items(display: display, detail: detail, artwork: artwork)
            session?.player?.currentItem?.externalMetadata = infoItems
        }
    }

    /// Runs for every item the session creates, so a restarted transcode or a re-resolved stream
    /// keeps its info panel and its Up Next proposal.
    func configure(item: AVPlayerItem) {
        item.externalMetadata = infoItems
        item.nextContentProposal = makeProposal()
    }
}
