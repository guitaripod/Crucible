import Foundation

/// The audio and subtitle a viewer asked for: nil subtitle for none, nil audio for the file's default.
package struct StreamChoice: Equatable, Sendable {
    package let subtitleId: Int?
    package let audioStreamId: Int?

    package init(subtitleId: Int?, audioStreamId: Int?) {
        self.subtitleId = subtitleId
        self.audioStreamId = audioStreamId
    }

    /// Whether `stream` already carries this choice, so showing or hiding its subtitle is all it takes: the same audio plays, and
    /// the subtitle is the track travelling with it or none. A subtitle burned into the picture can only stay as it is.
    package func keepsStream(of stream: ResolvedStream, playingAudio: Int?) -> Bool {
        let audio = { (id: Int?) in PlaybackTrackMenu.playingAudioId(stream.audioTracks, selectedId: id) }
        guard audio(audioStreamId) == audio(playingAudio) else { return false }
        switch stream.subtitleDelivery {
        case .burned:
            return subtitleId != nil && subtitleId == stream.chosenSubtitleId
        case .none:
            return subtitleId == nil
        case .track:
            return subtitleId == nil || subtitleId == stream.chosenSubtitleId
        }
    }
}
