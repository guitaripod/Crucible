import AVKit
import CrucibleCore
import CrucibleMedia
import MidgarCore
@preconcurrency import UIKit

extension PlayerCoordinator {
    /// Gives the system player's scrubber its preview (`ScrubPreview`), which reads whatever session is on screen, so it
    /// goes on working when the next episode takes over the player.
    func installScrubPreview(on playerVC: AVPlayerViewController) {
        playerVC.loadViewIfNeeded()
        let preview = ScrubPreview(playerController: playerVC)
        preview.moment = { [weak self] place in
            guard let self, let item = session.player?.currentItem else { return nil }
            let duration = item.duration.seconds
            guard duration.isFinite, duration > 0 else { return nil }
            return ScrubPreview.Moment(clock: place * duration, title: place * duration + session.streamOffset)
        }
        preview.chapterTitle = { [weak self] seconds in
            guard let chapters = self?.session.stream?.chapters, !chapters.isEmpty else { return nil }
            return ChapterList.current(chapters, at: seconds)?.title
        }
        preview.onScrubbing = { [weak self] scrubbing, landing in
            self?.session.viewerScrubbing(scrubbing, landing: landing)
        }
        scrubPreview = preview
        followScrubStills()
    }

    /// Points the preview at the stills of the title on screen: a download's own file, or the server's stills of the file
    /// being played when it has made them. A title with neither keeps a preview of the time and chapter alone.
    func followScrubStills() {
        guard let scrubPreview else { return }
        if let offline = request.offline {
            scrubPreview.stills = FileScrubStills(fileURL: offline.fileURL)
        } else if let part = ScrubStills.part(of: session.stream?.media) {
            if (scrubPreview.stills as? ServerScrubStills)?.partID == part.id { return }
            let stills = ServerScrubStills(api: api, partID: part.id)
            stills.isStreamStarved = { [weak self] in
                self?.session.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
            scrubPreview.stills = stills
        } else {
            scrubPreview.stills = nil
        }
    }
}
