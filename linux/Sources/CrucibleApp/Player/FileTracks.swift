import CrucibleCore

/// The server's streams of a file playing directly, as mpv's tracks: mpv numbers each kind from 1 in the order the file carries
/// them, the order the server lists the file's own streams in. A subtitle with a key sits beside the file and is fetched and
/// added instead.
struct FileTracks {
    /// The audio track to open with: the one chosen, else the file's default, else its first.
    let audio: Int?
    /// The subtitle in the file to open with; nil when subtitles are off or the chosen one sits beside the file.
    let subtitle: Int?
    /// The chosen subtitle when it sits beside the file.
    let sidecar: PlexStream?

    init(_ stream: ResolvedStream) {
        let audioId = stream.chosenAudioStreamId
            ?? stream.audioTracks.first { $0.isDefault == true }?.id
            ?? stream.audioTracks.first?.id
        audio = Self.audioTrack(audioId, among: stream.audioTracks)
        let chosen = stream.subtitles.first { $0.id != nil && $0.id == stream.chosenSubtitleId }
        subtitle = chosen.flatMap { Self.subtitleTrack($0.id, among: stream.subtitles) }
        sidecar = chosen?.key == nil ? nil : chosen
    }

    /// mpv options that open the file on these tracks, so it starts in the right language instead of switching once open.
    var loadOptions: KeyValuePairs<String, String> {
        ["aid": audio.map(String.init) ?? "auto", "sid": subtitle.map(String.init) ?? "no"]
    }

    /// mpv's number for the audio stream `id`.
    static func audioTrack(_ id: Int?, among tracks: [PlexStream]) -> Int? {
        guard let id else { return nil }
        return tracks.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// mpv's number for the subtitle stream `id` when the file carries it; nil for one beside the file.
    static func subtitleTrack(_ id: Int?, among subtitles: [PlexStream]) -> Int? {
        guard let id else { return nil }
        return subtitles.filter { $0.key == nil }.firstIndex { $0.id == id }.map { $0 + 1 }
    }
}
