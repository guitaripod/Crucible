import Foundation

/// Everything the movie and episode detail screens derive from one `PlexMetadata`: copy, progress,
/// tracks, cast, facts and related titles. Pure value logic; screens render it.
package struct MovieDetailModel: Sendable {
    /// How far through an item the viewer is, as a fraction and in words.
    package struct PlaybackProgress: Equatable, Sendable {
        package let fraction: Double
        package let text: String
        package let accessibilityText: String
    }

    private static let crewLimit = 2
    private static let castLimit = 20

    package let item: PlexMetadata
    package let showRatingKey: String?
    package let seasonRatingKey: String?

    package init(item: PlexMetadata, showRatingKey: String? = nil, seasonRatingKey: String? = nil) {
        self.item = item
        self.showRatingKey = showRatingKey
        self.seasonRatingKey = seasonRatingKey
    }

    package var isEpisode: Bool {
        item.mediaType == "episode"
    }

    package var showKey: String? {
        showRatingKey ?? item.grandparentRatingKey
    }

    package var seasonKey: String? {
        seasonRatingKey ?? item.parentRatingKey
    }

    /// Episodes link to their show and, within a season, to the next episode.
    package var hasLinks: Bool {
        isEpisode && (showKey != nil || seasonKey != nil)
    }

    package var showRoute: DetailRoute? {
        showKey.map { .show(ratingKey: $0, initialSeasonKey: seasonKey) }
    }

    package func nextEpisodeRoute(_ next: PlexMetadata) -> DetailRoute? {
        seasonKey.map { .episode(next, showRatingKey: showKey, seasonRatingKey: $0) }
    }

    package var playTitle: String {
        hasResumePosition ? "Resume" : "Play"
    }

    package var playAccessibilityLabel: String {
        guard hasResumePosition else { return "Play \(item.title)" }
        if let left = DetailFormat.spokenDuration(item.durationSecs - item.positionSecs), item.durationSecs > item.positionSecs {
            return "Resume \(item.title), \(left) left"
        }
        return "Resume \(item.title)"
    }

    package var watchedToggleTitle: String {
        WatchedService.title(isWatched: item.isWatched)
    }

    /// The position playback starts from: the beginning for an episode already watched, otherwise the
    /// downloaded copy's own resume point when playing offline, else the server's.
    package func resumePosition(offlineResumeSecs: Double?) -> Double {
        guard !item.isWatched else { return 0 }
        return offlineResumeSecs ?? item.positionSecs
    }

    /// Whether there is somewhere to resume: a watched item has nothing left to resume, whatever offset
    /// the server or a download still carries.
    package var hasProgress: Bool {
        !item.isWatched && item.positionSecs > 0 && item.durationSecs > item.positionSecs
    }

    package var hasResumePosition: Bool {
        !item.isWatched && item.positionSecs > 0
    }

    package var progress: PlaybackProgress {
        let fraction = item.durationSecs > 0 ? item.positionSecs / item.durationSecs : 0
        let text = DetailFormat.remaining(position: item.positionSecs, duration: item.durationSecs) ?? ""
        let spokenLeft = DetailFormat.spokenDuration(item.durationSecs - item.positionSecs).map { "\($0) left" } ?? ""
        return PlaybackProgress(
            fraction: fraction,
            text: text,
            accessibilityText: "\(Int((fraction * 100).rounded())) percent watched, \(spokenLeft)"
        )
    }

    package var heroInfo: DetailHeroInfo {
        let eyebrow = self.eyebrow
        let dateText: String? = isEpisode
            ? (Formatters.plexDate(item.originallyAvailableAt) ?? item.year.map(String.init))
            : item.year.map(String.init)
        var leading: [String] = dateText.map { [$0] } ?? []
        if let runtime = DetailFormat.runtime(item.durationSecs) { leading.append(runtime) }
        let rating = DetailFormat.ratingParts(audience: item.audienceRating, critic: item.rating)
        let meta = DetailMeta(leading: leading, star: rating.star, trailing: rating.trailing)

        let audio = DetailFormat.primaryAudioStream(item)
        let badges = DetailFormat.technicalBadges(for: item, contentRating: item.contentRating, audio: audio)

        var spoken = [item.title]
        if isEpisode {
            if let show = item.grandparentTitle { spoken.append(show) }
            if let season = item.parentIndex, let episode = item.index { spoken.append("season \(season) episode \(episode)") }
        } else if !eyebrow.isEmpty {
            spoken.append(eyebrow.lowercased())
        }
        if let dateText { spoken.append(dateText) }
        if let duration = DetailFormat.spokenDuration(item.durationSecs) { spoken.append(duration) }
        if let ratingText = DetailFormat.spokenRating(audience: item.audienceRating, critic: item.rating) { spoken.append(ratingText) }
        spoken.append(contentsOf: badges)

        return DetailHeroInfo(
            eyebrow: eyebrow,
            title: item.title,
            meta: meta,
            badges: badges,
            accessibilityText: spoken.joined(separator: ", ")
        )
    }

    private var eyebrow: String {
        switch item.mediaType {
        case "episode":
            return ["EPISODE", DetailFormat.episodeCode(season: item.parentIndex, episode: item.index)]
                .compactMap { $0 }
                .joined(separator: " · ")
        case "movie": return "MOVIE"
        default: return item.mediaType == "unknown" ? "" : item.mediaType.uppercased()
        }
    }

    /// Episodes show their still (or the season or show art behind it), everything else its backdrop or poster.
    package var heroArtwork: DetailArtwork {
        if isEpisode {
            return DetailArtwork(path: item.thumb ?? item.art ?? item.grandparentArt, isBackdrop: item.thumb != nil || item.art != nil)
        }
        return DetailArtwork(path: item.art ?? item.thumb, isBackdrop: item.art != nil)
    }

    package var hasSummary: Bool {
        !(item.summary ?? "").isEmpty
    }

    package var hasTracks: Bool {
        !item.audioStreams.isEmpty || !item.subtitleStreams.isEmpty
    }

    /// Keeps the viewer's audio and subtitle picks when the new metadata still has them, and otherwise
    /// falls back to the default audio track and no subtitles.
    package func reconciledTracks(audioId: Int?, subtitleId: Int?) -> TrackSelection {
        let audioStreams = item.audioStreams
        var audio = audioId
        if audio == nil || !audioStreams.contains(where: { $0.id == audio }) {
            audio = (audioStreams.first(where: { $0.isDefault == true }) ?? audioStreams.first)?.id
        }
        var subtitle = subtitleId
        if let current = subtitle, !item.subtitleStreams.contains(where: { $0.id == current }) {
            subtitle = nil
        }
        return TrackSelection(audioId: audio, subtitleId: subtitle)
    }

    /// The Audio button's value, or nil when the item has no audio tracks.
    package func audioButtonValue(selectedId: Int?) -> String? {
        guard !item.audioStreams.isEmpty else { return nil }
        return DetailFormat.primaryAudioStream(item, selectedId: selectedId).map(DetailFormat.audioValue) ?? "Default"
    }

    /// The Subtitles button's value, or nil when the item has no subtitle tracks.
    package func subtitleButtonValue(selectedId: Int?) -> String? {
        let subtitles = item.subtitleStreams
        guard !subtitles.isEmpty else { return nil }
        return subtitles.first { $0.id != nil && $0.id == selectedId }.map(DetailFormat.subtitleValue) ?? "Off"
    }

    package func audioOptions(selectedId: Int?) -> [TrackOption] {
        item.audioStreams.map { stream in
            let detail = DetailFormat.audioDetail(stream)
            return TrackOption(
                id: stream.id,
                title: stream.displayTitle ?? DetailFormat.languageName(stream),
                detail: detail.isEmpty ? nil : detail,
                isSelected: stream.id == selectedId,
                isEnabled: true
            )
        }
    }

    /// Image-based subtitles cannot be rendered by the player, so they are listed but disabled.
    package func subtitleOptions(selectedId: Int?) -> [TrackOption] {
        item.subtitleStreams.map { stream in
            let detail = DetailFormat.subtitleDetail(stream)
            return TrackOption(
                id: stream.id,
                title: stream.displayTitle ?? DetailFormat.languageName(stream),
                detail: detail.isEmpty ? nil : detail,
                isSelected: !stream.isBitmap && stream.id != nil && stream.id == selectedId,
                isEnabled: !stream.isBitmap
            )
        }
    }

    /// Up to two directors and two writers as cast-rail entries; a person who does both appears once with both roles.
    package var crew: [PlexRole] {
        var order = [String]()
        var roles = [String: [String]]()
        let directors = item.directors.prefix(Self.crewLimit).map { ($0, "Director") }
        let writers = item.writers.prefix(Self.crewLimit).map { ($0, "Writer") }
        for (name, role) in directors + writers {
            if roles[name] == nil { order.append(name) }
            roles[name, default: []].append(role)
        }
        return order.map { PlexRole(id: nil, tag: $0, role: roles[$0]?.joined(separator: ", "), thumb: nil) }
    }

    /// Crew first, then up to twenty cast, without the same person twice.
    package var castAndCrew: [PlexRole] {
        var seen = Set<PlexRole>()
        return (crew + item.cast.prefix(Self.castLimit)).filter { seen.insert($0).inserted }
    }

    /// The rows of the Details grid, in display order, without repeats.
    package var facts: [DetailFact] {
        var facts: [DetailFact] = []
        func add(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            facts.append(DetailFact(key: key, value: value))
        }
        let directors = item.directors.prefix(Self.crewLimit)
        add(directors.count > 1 ? "Directors" : "Director", directors.isEmpty ? nil : directors.joined(separator: ", "))
        let writers = item.writers.prefix(Self.crewLimit)
        add(writers.count > 1 ? "Writers" : "Writer", writers.isEmpty ? nil : writers.joined(separator: ", "))
        add("Studio", item.studio)
        if isEpisode {
            add("Aired", Formatters.plexDate(item.originallyAvailableAt))
        }
        add("Added", DetailFormat.addedDate(item.addedAt))
        add("File", DetailFormat.fileFact(item))
        add("Audio", DetailFormat.audioFact(DetailFormat.primaryAudioStream(item)))
        var seen = Set<DetailFact>()
        return facts.filter { seen.insert($0).inserted }
    }

    package var related: [PlexMetadata] {
        DetailRelated.items(in: item)
    }

    /// The episode after `ratingKey` within `episodes`, which are one season's episodes: the last
    /// episode of a season has no next episode, the following season is never entered.
    package static func nextEpisode(after ratingKey: String, in episodes: [PlexMetadata]) -> PlexMetadata? {
        EpisodeOrder.next(after: ratingKey, in: episodes)
    }
}

/// The "More Like This" shelf shared by movie and show screens.
package enum DetailRelated {
    package static let limit = 18

    /// Titles from every related hub, the screen's own item excluded, without repeats, capped at eighteen.
    package static func items(in item: PlexMetadata) -> [PlexMetadata] {
        var seen = Set<String>()
        return Array(
            item.relatedHubs
                .flatMap { $0.Metadata ?? [] }
                .filter { $0.id != item.id && seen.insert($0.id).inserted }
                .prefix(limit)
        )
    }
}
