import Foundation

/// The audio and subtitle choices a player offers for the streams the server listed, the way the
/// detail screens list them: image-based subtitles are shown but cannot be picked, because the
/// player cannot render them.
package enum PlaybackTrackMenu {
    /// The audio stream that is playing: the user's pick, else the default track, else the first.
    package static func playingAudioId(_ tracks: [PlexStream], selectedId: Int?) -> Int? {
        if let selectedId, tracks.contains(where: { $0.id == selectedId }) { return selectedId }
        return (tracks.first(where: { $0.isDefault == true }) ?? tracks.first)?.id
    }

    package static func audioOptions(_ tracks: [PlexStream], selectedId: Int?) -> [TrackOption] {
        let playing = playingAudioId(tracks, selectedId: selectedId)
        return tracks.map { stream in
            let detail = DetailFormat.audioDetail(stream)
            return TrackOption(
                id: stream.id,
                title: stream.displayTitle ?? DetailFormat.languageName(stream),
                detail: detail.isEmpty ? nil : detail,
                isSelected: stream.id != nil && stream.id == playing,
                isEnabled: true
            )
        }
    }

    /// "Off" first, then every subtitle stream.
    package static func subtitleOptions(_ tracks: [PlexStream], selectedId: Int?) -> [TrackOption] {
        let off = TrackOption(id: nil, title: "Off", detail: nil, isSelected: selectedId == nil, isEnabled: true)
        let streams = tracks.map { stream in
            let detail = DetailFormat.subtitleDetail(stream)
            return TrackOption(
                id: stream.id,
                title: stream.displayTitle ?? DetailFormat.languageName(stream),
                detail: detail.isEmpty ? nil : detail,
                isSelected: !stream.isBitmap && stream.id != nil && stream.id == selectedId,
                isEnabled: !stream.isBitmap
            )
        }
        return [off] + streams
    }
}
