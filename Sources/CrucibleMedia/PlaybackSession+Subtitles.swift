import AVFoundation
import CrucibleCore
import Foundation
import MidgarCore

extension PlaybackSession {
    /// Whether the subtitle travelling with the stream is a track the player shows and hides itself.
    package var subtitleIsTrack: Bool {
        stream?.subtitleDelivery == .track
    }

    /// Shows the delivered subtitle on `item` when the viewer wants it and hides it otherwise, then follows the viewer's own
    /// changes through the system controls and Siri for as long as `item` plays. The selection is made once the item is ready to
    /// play: the system player sets its own default subtitle at that moment, silently, over anything chosen before.
    func syncSubtitles(on item: AVPlayerItem) {
        subtitleSyncTask?.cancel()
        stopFollowingSubtitles()
        if subtitleItem != ObjectIdentifier(item) {
            subtitleGroup = nil
            subtitleItem = ObjectIdentifier(item)
        }
        subtitleSyncTask = Task { [weak self] in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible), await Self.becomesReady(item) else { return }
            guard let self, !Task.isCancelled, !isStopped, player?.currentItem === item else { return }
            subtitleGroup = group
            applySubtitleSelection(to: item, group: group)
            followSubtitleChanges(of: item)
        }
    }

    /// Waits until `item` is ready to play; false when it fails or the wait is cancelled.
    private static func becomesReady(_ item: AVPlayerItem) async -> Bool {
        if item.status == .readyToPlay { return true }
        let statuses = AsyncStream<AVPlayerItem.Status> { continuation in
            let observation = item.observe(\.status, options: [.initial, .new]) { observed, _ in
                continuation.yield(observed.status)
            }
            continuation.onTermination = { _ in observation.invalidate() }
        }
        for await status in statuses {
            switch status {
            case .readyToPlay: return true
            case .failed: return false
            default: continue
            }
        }
        return false
    }

    /// Selects the option for `selectedSubtitleId` in `group`, or none. The selection is made even when the item already reports
    /// it: what an item reports while it settles is not always what it shows.
    func applySubtitleSelection(to item: AVPlayerItem, group: AVMediaSelectionGroup) {
        let wanted = option(forSubtitle: selectedSubtitleId, in: group)
        let current = item.currentMediaSelection.selectedMediaOption(in: group)
        MidgarLog.notice("Subtitles on the item ratingKey=\(request.ratingKey) options=\(group.options.count) wanted=\(wanted?.displayName ?? "none") was=\(current?.displayName ?? "none")", category: .playback)
        guard wanted != nil || group.allowsEmptySelection else { return }
        appliedSubtitleOption = wanted
        item.select(wanted, in: group)
    }

    /// Whether the item playing carries the subtitle track the stream was resolved with. A transcode rebuilt while the subtitle
    /// was hidden comes back without it.
    var carriesSubtitleTrack: Bool {
        !(subtitleGroup?.options.isEmpty ?? true)
    }

    /// Shows or hides the subtitle already travelling with the stream, without asking the server for a new stream, and tells the
    /// server, so the next playback of the title (on any Plex app) starts the same way.
    func showDeliveredSubtitle(_ subtitleId: Int?) {
        selectedSubtitleId = subtitleId
        rememberLanguagesForShow()
        rememberSelectionOnServer()
        if let item = player?.currentItem {
            syncSubtitles(on: item)
        }
        MidgarLog.notice("Subtitle \(subtitleId == nil ? "hidden" : "shown") in the player ratingKey=\(request.ratingKey)", category: .playback)
        emit(.tracksChanged)
    }

    /// Sends the audio and subtitle playing now to the server, after any update still on its way, so they arrive in order.
    private func rememberSelectionOnServer() {
        guard let stream, let partId = stream.media?.Part?.first?.id else { return }
        let previous = selectionUpdateTask
        let audio = PlaybackTrackMenu.playingAudioId(stream.audioTracks, selectedId: selectedAudioStreamId)
        let subtitle = selectedSubtitleId
        let api = api
        let ratingKey = request.ratingKey
        selectionUpdateTask = Task {
            await previous?.value
            await StreamResolver.applyStreamSelection(api: api, ratingKey: ratingKey, partId: partId, audioStreamId: audio, subtitleStreamId: subtitle)
        }
    }

    /// The option that shows `subtitleId`: the transcode's WebVTT rendition, or the file's own track in the same language when
    /// the file plays directly. Nil for no subtitle, or one the item does not carry.
    private func option(forSubtitle subtitleId: Int?, in group: AVMediaSelectionGroup) -> AVMediaSelectionOption? {
        guard let subtitleId, let stream, stream.chosenSubtitleId == subtitleId, stream.subtitleDelivery == .track else { return nil }
        if !stream.isDirectPlay { return group.options.first }
        guard let wanted = stream.subtitles.first(where: { $0.id == subtitleId }) else { return nil }
        let fileTracks = stream.subtitles.filter(StreamResolver.isFileTrack)
        return SubtitleOptionMatch.option(for: wanted, among: fileTracks, in: group.options)
    }

    /// The stream of the item that `option` shows, for a choice the viewer made outside the app's menus.
    private func subtitleId(showing option: AVMediaSelectionOption?, in group: AVMediaSelectionGroup) -> Int? {
        guard let option, let stream else { return nil }
        if !stream.isDirectPlay { return stream.subtitleDelivery == .track ? stream.chosenSubtitleId : nil }
        let fileTracks = stream.subtitles.filter(StreamResolver.isFileTrack)
        return SubtitleOptionMatch.stream(for: option, among: fileTracks, in: group.options)?.id
    }

    /// Registered once `item`'s subtitles are in place, so the player's own pick when the item loads is never taken for the
    /// viewer's.
    private func followSubtitleChanges(of item: AVPlayerItem) {
        subtitleObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let item = self.player?.currentItem, let group = self.subtitleGroup else { return }
                self.viewerChangedSubtitle(to: item.currentMediaSelection.selectedMediaOption(in: group), in: group)
            }
        }
    }

    /// Takes a change of the item's subtitle that the app did not make itself as the viewer's own choice.
    private func viewerChangedSubtitle(to option: AVMediaSelectionOption?, in group: AVMediaSelectionGroup) {
        guard option != appliedSubtitleOption else { return }
        appliedSubtitleOption = option
        let shown = subtitleId(showing: option, in: group)
        guard shown != selectedSubtitleId, option == nil || shown != nil else { return }
        selectedSubtitleId = shown
        subtitlesTurnedOff = shown == nil
        rememberLanguagesForShow()
        rememberSelectionOnServer()
        MidgarLog.notice("Subtitle \(shown == nil ? "turned off" : "turned on") from the system controls ratingKey=\(request.ratingKey)", category: .playback)
        emit(.tracksChanged)
    }

    func stopFollowingSubtitles() {
        if let subtitleObserver {
            NotificationCenter.default.removeObserver(subtitleObserver)
        }
        subtitleObserver = nil
    }
}

/// Pairs the subtitle streams the server lists with the subtitle options of a file the player opens itself. The player names a
/// track by its language alone, so streams and options of one language are paired in file order.
enum SubtitleOptionMatch {
    static func option(for stream: PlexStream, among streams: [PlexStream], in options: [AVMediaSelectionOption]) -> AVMediaSelectionOption? {
        let sameLanguage = streams.filter { sameLanguage($0, stream) }
        guard let index = sameLanguage.firstIndex(where: { $0.id == stream.id }) else { return nil }
        let candidates = options.filter { matches(stream, $0) }
        return candidates.indices.contains(index) ? candidates[index] : nil
    }

    static func stream(for option: AVMediaSelectionOption, among streams: [PlexStream], in options: [AVMediaSelectionOption]) -> PlexStream? {
        streams.first { Self.option(for: $0, among: streams, in: options) == option }
    }

    private static func sameLanguage(_ one: PlexStream, _ other: PlexStream) -> Bool {
        guard let first = languageCode(one.bcp47Language), let second = languageCode(other.bcp47Language) else { return false }
        return first == second
    }

    private static func matches(_ stream: PlexStream, _ option: AVMediaSelectionOption) -> Bool {
        guard let wanted = languageCode(stream.bcp47Language), let offered = languageCode(option.extendedLanguageTag ?? option.locale?.identifier) else {
            return false
        }
        return wanted == offered
    }

    private static func languageCode(_ tag: String?) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        return StreamResolver.alpha3(tag)
    }
}
