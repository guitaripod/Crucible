import AVKit
import CrucibleCore
import CrucibleMedia
import MidgarCore
import UIKit

extension TVPlayerCoordinator {
    /// Audio and Subtitles menus in the transport bar for the streams the server lists, then the sleep timer. Picking a
    /// track re-resolves the stream, exactly like choosing it on the detail screen before pressing Play: a non-default
    /// audio track or a subtitle is burned in by the transcoder, and image-based subtitles are listed but disabled.
    func refreshTrackMenus() {
        guard let session, let stream = session.stream else {
            playerVC.transportBarCustomMenuItems = []
            return
        }
        var menus: [UIMenuElement] = []
        if stream.audioTracks.count > 1 {
            let options = PlaybackTrackMenu.audioOptions(stream.audioTracks, selectedId: session.selectedAudioStreamId)
            menus.append(menu(title: String(localized: "Audio"), symbol: "speaker.wave.2", options: options) { [weak self] id in
                self?.selectStreams(subtitleId: session.selectedSubtitleId, audioId: id)
            })
        }
        if !stream.subtitles.isEmpty {
            let options = PlaybackTrackMenu.subtitleOptions(stream.subtitles, selectedId: session.selectedSubtitleId)
            menus.append(menu(title: String(localized: "Subtitles"), symbol: "captions.bubble", options: options) { [weak self] id in
                self?.selectStreams(subtitleId: id, audioId: session.selectedAudioStreamId)
            })
        }
        menus.append(sleepMenu(session))
        playerVC.transportBarCustomMenuItems = menus
        playerVC.customInfoViewControllers = [TVStreamInfoViewController(lines: StreamInfo.lines(
            stream: stream,
            route: HomeServerRoute.classify(stream.url),
            quality: QualityPolicy.current(for: stream.url),
            audioId: session.selectedAudioStreamId,
            subtitleId: session.selectedSubtitleId
        ))]
    }

    /// The sleep timer: a few lengths of time or the end of what is playing, with the time left in the menu's title.
    private func sleepMenu(_ session: PlaybackSession) -> UIMenu {
        let timer = session.sleepTimer
        let off = UIAction(title: SleepTimer.off, state: timer == nil ? .on : .off) { [weak self] _ in self?.setSleepTimer(nil) }
        let choices = SleepTimerChoice.all.map { choice in
            UIAction(title: choice.title(isEpisode: request.isEpisode), state: timer?.choice == choice ? .on : .off) { [weak self] _ in
                self?.setSleepTimer(choice)
            }
        }
        return UIMenu(
            title: timer?.menuTitle(isEpisode: request.isEpisode) ?? SleepTimer.title,
            image: UIImage(systemName: timer == nil ? "moon.zzz" : "moon.zzz.fill"),
            children: [off] + choices
        )
    }

    private func setSleepTimer(_ choice: SleepTimerChoice?) {
        session?.setSleepTimer(choice)
        carriedSleepTimer = session?.sleepTimer
        refreshTrackMenus()
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
