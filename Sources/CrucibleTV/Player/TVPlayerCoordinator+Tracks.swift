import AVKit
import CrucibleCore
import CrucibleMedia
import MidgarCore
import UIKit

extension TVPlayerCoordinator {
    /// Audio and Subtitles menus in the transport bar for the streams the server lists. Picking one
    /// re-resolves the stream, exactly like choosing it on the detail screen before pressing Play:
    /// a non-default audio track or a subtitle is burned in by the transcoder, and image-based
    /// subtitles are listed but disabled.
    func refreshTrackMenus() {
        guard let session, let stream = session.stream else {
            playerVC.transportBarCustomMenuItems = []
            return
        }
        var menus: [UIMenuElement] = []
        if stream.audioTracks.count > 1 {
            let options = PlaybackTrackMenu.audioOptions(stream.audioTracks, selectedId: session.selectedAudioStreamId)
            menus.append(menu(title: "Audio", symbol: "speaker.wave.2", options: options) { [weak self] id in
                self?.selectStreams(subtitleId: session.selectedSubtitleId, audioId: id)
            })
        }
        if !stream.subtitles.isEmpty {
            let options = PlaybackTrackMenu.subtitleOptions(stream.subtitles, selectedId: session.selectedSubtitleId)
            menus.append(menu(title: "Subtitles", symbol: "captions.bubble", options: options) { [weak self] id in
                self?.selectStreams(subtitleId: id, audioId: session.selectedAudioStreamId)
            })
        }
        playerVC.transportBarCustomMenuItems = menus
    }

    private func menu(
        title: String,
        symbol: String,
        options: [TrackOption],
        select: @escaping @MainActor (Int?) -> Void
    ) -> UIMenu {
        let actions = options.map { option in
            UIAction(
                title: option.title,
                subtitle: option.detail,
                state: option.isSelected ? .on : .off,
                handler: { _ in select(option.id) }
            ).disabling(!option.isEnabled)
        }
        return UIMenu(title: title, image: UIImage(systemName: symbol), children: actions)
    }

    private func selectStreams(subtitleId: Int?, audioId: Int?) {
        guard let session else { return }
        MidgarLog.notice("Switching streams ratingKey=\(request.ratingKey) audio=\(String(describing: audioId)) subtitle=\(String(describing: subtitleId))", category: .playback)
        Task { [weak self] in
            do {
                try await session.selectStreams(subtitleId: subtitleId, audioStreamId: audioId)
                self?.refreshTrackMenus()
            } catch {
                guard !Task.isCancelled else { return }
                self?.presentFailure(error.localizedDescription, retry: { [weak self] in self?.selectStreams(subtitleId: subtitleId, audioId: audioId) })
            }
        }
    }
}

private extension UIAction {
    func disabling(_ disabled: Bool) -> UIAction {
        if disabled { attributes.insert(.disabled) }
        return self
    }
}
