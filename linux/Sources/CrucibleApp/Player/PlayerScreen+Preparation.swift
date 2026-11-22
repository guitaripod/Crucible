import CrucibleCore
import Foundation

/// What the player readies beside a stream: the sound output's abilities before the stream is resolved, and the intro's
/// marker moved onto the picture's own edges while the stream plays.
extension PlayerScreen {
    /// Asks the sound output what it takes before the stream is resolved; a check that ends after the first file started
    /// still reaches mpv, which reopens its audio for the change.
    func checkAudioOutput() {
        let setting = Preferences.audioPassthrough
        Task { [weak self] in
            let output = await AudioOutput.prepare(setting)
            guard let self else { return }
            self.player?.outputChannels = output.channels
            guard output.spdif != self.spdifCodecs else { return }
            self.spdifCodecs = output.spdif
            if self.stream != nil { self.applyAudioFilters() }
        }
    }

    /// Moves the intro's marker onto the picture's own edges, as a paired Crucible Server measured them or else as ffmpeg
    /// here reads them (`MarkerSharpener`), while the same stream still plays.
    func sharpenIntro(of resolved: ResolvedStream, ratingKey: String, api: APIClient) {
        let segments = resolved.segments
        guard segments.contains(where: { $0.kind == .intro && !$0.fromChapter }) else { return }
        let partKey = resolved.media?.Part?.first?.key
        Task { [weak self] in
            let partURL: URL?
            if resolved.isDirectPlay {
                partURL = resolved.url
            } else if let partKey {
                partURL = StreamResolver.directPlayURL(baseURL: await api.baseURL, partKey: partKey, token: api.token)
            } else {
                partURL = nil
            }
            let fromServer = await IntroSharpening.fromServer(segments, ratingKey: ratingKey)
            let local: [SkipMarker]? = if fromServer == nil, let partURL {
                await MarkerSharpener.sharpen(segments, ratingKey: ratingKey, partURL: partURL)
            } else {
                nil
            }
            guard let sharpened = fromServer ?? local,
                  let self, self.stream?.sessionId == resolved.sessionId, self.stream?.url == resolved.url, self.segments == segments else { return }
            self.segments = sharpened
        }
    }
}
