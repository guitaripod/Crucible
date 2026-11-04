import Foundation

/// The audio and subtitle a viewer chose, held as languages rather than stream ids. An id names a stream of one file, so the
/// next episode, or the same show next week, looks for its own streams in the languages (and the kind of track, such as a
/// commentary or forced subtitles) the viewer picked.
package struct TrackLanguages: Codable, Equatable, Sendable {
    package struct Track: Codable, Equatable, Sendable {
        package let language: String
        package let title: String?
        package let forced: Bool
        package let channels: Int?

        package init(language: String, title: String? = nil, forced: Bool = false, channels: Int? = nil) {
            self.language = language
            self.title = title
            self.forced = forced
            self.channels = channels
        }
    }

    /// The audio track to prefer, or nil for whatever the file plays by default.
    package let audio: Track?
    /// The subtitle to show, or nil for none.
    package let subtitle: Track?

    package init(audio: Track?, subtitle: Track?) {
        self.audio = audio
        self.subtitle = subtitle
    }

    /// What the chosen ids of `subtitles` and `audioTracks` amount to as languages. The file's default audio needs no
    /// language: every episode's own default plays.
    package init(subtitleId: Int?, audioStreamId: Int?, subtitles: [PlexStream], audioTracks: [PlexStream]) {
        let defaultAudio = audioTracks.first { $0.isDefault == true } ?? audioTracks.first
        let chosenAudio = audioTracks.first { $0.id != nil && $0.id == audioStreamId && $0.id != defaultAudio?.id }
        audio = chosenAudio.flatMap(Self.track)
        subtitle = subtitles.first { $0.id != nil && $0.id == subtitleId }.flatMap(Self.track)
    }

    /// Whether this asks for nothing beyond the file's defaults.
    package var isDefault: Bool { audio == nil && subtitle == nil }

    /// The ids of the streams in `subtitles` and `audioTracks` that match these languages; nil where nothing matches or the
    /// default serves. A forced subtitle is only matched by a forced one, so a viewer who reads just the foreign dialogue
    /// never gets a full subtitle track instead.
    package func streamIds(subtitles: [PlexStream], audioTracks: [PlexStream]) -> (subtitleId: Int?, audioStreamId: Int?) {
        let defaultAudio = audioTracks.first { $0.isDefault == true } ?? audioTracks.first
        let audioId = audio.flatMap { Self.best(for: $0, in: audioTracks) }?.id
        let subtitleId = subtitle.flatMap { wanted in
            Self.best(for: wanted, in: subtitles.filter { ($0.forced == true) == wanted.forced })
        }?.id
        return (subtitleId, audioId == defaultAudio?.id ? nil : audioId)
    }

    private static func track(_ stream: PlexStream) -> Track? {
        guard let language = stream.languageKey else { return nil }
        return Track(language: language, title: stream.title, forced: stream.forced == true, channels: stream.channels)
    }

    /// The stream in `wanted`'s language that is most like it: the same kind of track by title, then the same channel
    /// count, then the first in that language.
    private static func best(for wanted: Track, in streams: [PlexStream]) -> PlexStream? {
        let same = streams.filter { $0.languageKey == wanted.language }
        return same.first { wanted.title != nil && $0.title == wanted.title }
            ?? same.first { wanted.channels != nil && $0.channels == wanted.channels }
            ?? same.first
    }
}

/// The languages last chosen on each show, so a show picked up again, on any episode, starts in them. Kept per server and
/// for the `limit` most recently changed shows.
package enum ShowTrackMemory {
    private static let storageKey = "showTrackLanguages.v1"
    static let limit = 300

    private struct Entry: Codable {
        let languages: TrackLanguages
        let at: Date
    }

    package static func languages(forShow showKey: String?, server: String?, defaults: UserDefaults = .standard) -> TrackLanguages? {
        guard let key = key(showKey, server) else { return nil }
        return stored(defaults)[key]?.languages
    }

    /// Remembers `languages` for the show; the file's defaults are remembered by forgetting the show.
    package static func remember(_ languages: TrackLanguages, forShow showKey: String?, server: String?, now: Date = Date(), defaults: UserDefaults = .standard) {
        guard let key = key(showKey, server) else { return }
        var all = stored(defaults)
        all[key] = languages.isDefault ? nil : Entry(languages: languages, at: now)
        if all.count > limit {
            for stale in all.sorted(by: { $0.value.at < $1.value.at }).prefix(all.count - limit) {
                all[stale.key] = nil
            }
        }
        defaults.set(try? JSONEncoder().encode(all), forKey: storageKey)
    }

    package static func forgetAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    private static func key(_ showKey: String?, _ server: String?) -> String? {
        guard let showKey, !showKey.isEmpty else { return nil }
        return "\(server ?? "")|\(showKey)"
    }

    private static func stored(_ defaults: UserDefaults) -> [String: Entry] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }
}
