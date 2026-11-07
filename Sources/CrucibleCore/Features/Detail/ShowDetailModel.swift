import Foundation

/// Everything the show detail screen derives from a show, its seasons and the episodes of the
/// selected season: the up-next episode, season chips, the primary button, watched options and related titles.
package struct ShowDetailModel: Sendable {
    package enum UpNextKind: Equatable, Sendable {
        case resume
        case next
        case start
    }

    /// The episode the primary button plays and why.
    package struct UpNext: Equatable, Sendable {
        package let episode: PlexMetadata
        package let kind: UpNextKind
    }

    package struct SeasonChip: Equatable, Sendable {
        package let id: String
        package let title: String
        package let watchedText: String?
        package let isSelected: Bool
    }

    /// One "Mark ... Watched" or "Mark ... Unwatched" choice and the item it applies to.
    package struct WatchedOption: Equatable, Sendable {
        package let title: String
        package let ratingKey: String
        package let watched: Bool
    }

    /// The Mark Watched menu: choices for the whole show, then for the selected season.
    package struct WatchedOptions: Equatable, Sendable {
        package let show: [WatchedOption]
        package let season: [WatchedOption]
    }

    package let show: PlexMetadata
    package let seasons: [PlexMetadata]
    package let selectedSeasonKey: String?
    package let episodes: [PlexMetadata]
    package let allEpisodes: [PlexMetadata]
    package let episodesFailed: Bool
    package let upNext: UpNext?
    /// The show's Crucible Guides plan, when a guide covers it: which episodes the person's choices hide.
    package let essentials: EssentialsPlan?

    package var userRating: UserRating? {
        UserRating(plexValue: show.userRating)
    }

    package init(
        show: PlexMetadata,
        seasons: [PlexMetadata] = [],
        selectedSeasonKey: String? = nil,
        episodes: [PlexMetadata] = [],
        allEpisodes: [PlexMetadata] = [],
        episodesFailed: Bool = false,
        essentials: EssentialsPlan? = nil
    ) {
        self.show = show
        self.seasons = seasons
        self.selectedSeasonKey = selectedSeasonKey
        self.episodes = episodes
        self.allEpisodes = allEpisodes
        self.episodesFailed = episodesFailed
        self.essentials = essentials
        self.upNext = Self.computeUpNext(in: allEpisodes.isEmpty ? episodes : allEpisodes, hidden: essentials?.hiddenKeys ?? [])
    }

    package func replacingShow(_ show: PlexMetadata) -> ShowDetailModel {
        ShowDetailModel(show: show, seasons: seasons, selectedSeasonKey: selectedSeasonKey, episodes: episodes, allEpisodes: allEpisodes, episodesFailed: episodesFailed, essentials: essentials)
    }

    package func selectingSeason(_ key: String) -> ShowDetailModel {
        ShowDetailModel(show: show, seasons: seasons, selectedSeasonKey: key, episodes: episodes, allEpisodes: allEpisodes, essentials: essentials)
    }

    package func replacingEpisodes(_ episodes: [PlexMetadata]) -> ShowDetailModel {
        ShowDetailModel(show: show, seasons: seasons, selectedSeasonKey: selectedSeasonKey, episodes: episodes, allEpisodes: allEpisodes, essentials: essentials)
    }

    /// The same screen under a new Essentials plan, after the person changes their choice.
    package func replacingEssentials(_ essentials: EssentialsPlan?) -> ShowDetailModel {
        ShowDetailModel(show: show, seasons: seasons, selectedSeasonKey: selectedSeasonKey, episodes: episodes, allEpisodes: allEpisodes, episodesFailed: episodesFailed, essentials: essentials)
    }

    /// Selects `key` and clears the episode list, for screens that show a loading state until the
    /// new season's episodes arrive instead of the previous season's.
    package func loadingSeason(_ key: String) -> ShowDetailModel {
        ShowDetailModel(show: show, seasons: seasons, selectedSeasonKey: key, episodes: [], allEpisodes: allEpisodes, essentials: essentials)
    }

    /// The selected season's episodes could not be fetched: no episodes, flagged so a screen can offer Retry instead of "empty".
    package func failingEpisodes() -> ShowDetailModel {
        ShowDetailModel(show: show, seasons: seasons, selectedSeasonKey: selectedSeasonKey, episodes: [], allEpisodes: allEpisodes, episodesFailed: true, essentials: essentials)
    }

    package var selectedSeason: PlexMetadata? {
        seasons.first { $0.id == selectedSeasonKey }
    }

    package static func seasonTitle(_ season: PlexMetadata) -> String {
        season.title.isEmpty ? String(localized: "Season \(season.index ?? 0)") : season.title
    }

    /// "3 of 10 watched", or nil when the season has no episodes.
    package static func watchedText(_ season: PlexMetadata) -> String? {
        guard let total = season.leafCount, total > 0 else { return nil }
        return String(localized: "\(season.viewedLeafCount ?? 0) of \(total) watched")
    }

    package var isWatched: Bool {
        guard let total = show.leafCount, total > 0 else { return false }
        return (show.viewedLeafCount ?? 0) >= total
    }

    package var watchedAccessibilityLabel: String {
        isWatched ? String(localized: "Watched. Mark unwatched") : String(localized: "Mark watched")
    }

    package var seasonChips: [SeasonChip] {
        seasons.map {
            SeasonChip(id: $0.id, title: Self.seasonTitle($0), watchedText: Self.watchedText($0), isSelected: $0.id == selectedSeasonKey)
        }
    }

    package var selectedSeasonTitle: String {
        selectedSeason.map(Self.seasonTitle) ?? String(localized: "Season", comment: "A season of a TV show")
    }

    package var selectedSeasonWatchedText: String? {
        selectedSeason.flatMap(Self.watchedText)
    }

    package var heroInfo: DetailHeroInfo {
        var leading: [String] = []
        if let year = show.year { leading.append(String(year)) }
        let seasonCount = seasons.isEmpty ? (show.childCount ?? 0) : seasons.count
        if seasonCount > 0 { leading.append(seasonCount == 1 ? String(localized: "1 Season") : String(localized: "\(seasonCount) Seasons")) }
        let rating = DetailFormat.ratingParts(audience: show.audienceRating, critic: show.rating)
        let meta = DetailMeta(leading: leading, star: rating.star, trailing: rating.trailing)
        let sample = upNext?.episode ?? episodes.first
        let badges = DetailFormat.technicalBadges(for: sample, contentRating: show.contentRating, audio: nil)

        var spoken = [show.title, String(localized: "TV show")]
        spoken.append(contentsOf: leading)
        if let ratingText = DetailFormat.spokenRating(audience: show.audienceRating, critic: show.rating) { spoken.append(ratingText) }
        spoken.append(contentsOf: badges)

        return DetailHeroInfo(
            eyebrow: String(localized: "TV SHOW"),
            title: show.title,
            meta: meta,
            badges: badges,
            accessibilityText: spoken.joined(separator: ", ")
        )
    }

    package var heroArtwork: DetailArtwork {
        DetailArtwork(path: show.art ?? show.thumb, isBackdrop: show.art != nil)
    }

    package var hasSummary: Bool {
        !(show.summary ?? "").isEmpty
    }

    /// "Play S1 · E1" when nothing has been watched, "Continue S1 · E3" otherwise.
    package var primaryTitle: String {
        guard let upNext else { return String(localized: "Play", comment: "Button or menu label that starts playback") }
        let code = DetailFormat.episodeCode(season: upNext.episode.parentIndex, episode: upNext.episode.index)
        let verb = upNext.kind == .start ? String(localized: "Play", comment: "Button or menu label that starts playback") : String(localized: "Continue", comment: "Button label that continues watching the next episode")
        return [verb, code].compactMap { $0 }.joined(separator: " ")
    }

    package var primaryAccessibilityLabel: String {
        guard let upNext else { return String(localized: "Play", comment: "Button or menu label that starts playback") }
        let episode = upNext.episode
        let verb: String
        switch upNext.kind {
        case .start: verb = String(localized: "Play", comment: "Button or menu label that starts playback")
        case .resume: verb = String(localized: "Resume", comment: "Button or menu label that resumes playback from the saved position")
        case .next: verb = String(localized: "Continue", comment: "Button label that continues watching the next episode")
        }
        var parts = [String(localized: "\(verb) \(show.title)")]
        if let season = episode.parentIndex, let number = episode.index { parts.append(String(localized: "season \(season) episode \(number)")) }
        if upNext.kind == .resume, episode.durationSecs > episode.positionSecs,
           let left = DetailFormat.spokenDuration(episode.durationSecs - episode.positionSecs) {
            parts.append(String(localized: "\(left) left"))
        }
        return parts.joined(separator: ", ")
    }

    package var isPrimaryEnabled: Bool {
        upNext != nil
    }

    package func status(for episode: PlexMetadata, download: DownloadBadge = .idle) -> EpisodeStatus {
        EpisodeStatus(episode: episode, isUpNext: upNext?.episode.id == episode.id, download: download)
    }

    package var watchedOptions: WatchedOptions {
        var showOptions: [WatchedOption] = []
        if !isWatched {
            showOptions.append(WatchedOption(title: String(localized: "Mark Show Watched"), ratingKey: show.id, watched: true))
        }
        if (show.viewedLeafCount ?? 0) > 0 {
            showOptions.append(WatchedOption(title: String(localized: "Mark Show Unwatched"), ratingKey: show.id, watched: false))
        }
        var seasonOptions: [WatchedOption] = []
        if let season = selectedSeason {
            let name = Self.seasonTitle(season)
            let viewed = season.viewedLeafCount ?? 0
            let total = season.leafCount ?? 0
            if total == 0 || viewed < total {
                seasonOptions.append(WatchedOption(title: String(localized: "Mark \(name) Watched"), ratingKey: season.id, watched: true))
            }
            if viewed > 0 {
                seasonOptions.append(WatchedOption(title: String(localized: "Mark \(name) Unwatched"), ratingKey: season.id, watched: false))
            }
        }
        return WatchedOptions(show: showOptions, season: seasonOptions)
    }

    package var related: [PlexMetadata] {
        DetailRelated.items(in: show)
    }

    /// The season to show first: the one the caller came from, else the first with unwatched episodes, else the first.
    package static func initialSeasonKey(seasons: [PlexMetadata], preferred: String?) -> String? {
        let firstUnwatched = seasons.first {
            let watched = $0.viewedLeafCount ?? 0
            let total = $0.leafCount ?? 0
            return watched < total
        }
        if let preferred, seasons.contains(where: { $0.id == preferred }) {
            return preferred
        }
        return firstUnwatched?.id ?? seasons.first?.id
    }

    /// Keeps `current` while it still exists among `seasons`, else falls back to `initialSeasonKey`.
    package static func resolvedSeasonKey(current: String?, seasons: [PlexMetadata], preferred: String?) -> String? {
        if let current, seasons.contains(where: { $0.id == current }) {
            return current
        }
        return initialSeasonKey(seasons: seasons, preferred: preferred)
    }

    /// The episode the primary button plays: the episode the viewer touched most recently when it is still
    /// in progress, otherwise the first unwatched episode after the most recently watched one, and the very
    /// first episode once everything is watched. Following the most recent watch keeps this screen in step
    /// with the server's own Continue Watching, which is built from that too.
    package static func computeUpNext(in episodes: [PlexMetadata], hidden: Set<String> = []) -> UpNext? {
        let all = EpisodeOrder.sorted(episodes)
        let ordered = hidden.isEmpty ? all : all.filter { !hidden.contains($0.id) || ($0.positionSecs > 0 && !$0.isWatched) }
        guard let first = ordered.first else { return nil }
        let inProgress = ordered.filter { !$0.isWatched && $0.positionSecs > 0 }
        let watched = ordered.filter(\.isWatched)
        let engaged = ordered.filter { $0.isWatched || $0.positionSecs > 0 }
        guard let anchor = mostRecentlyViewed(engaged) ?? inProgress.first ?? watched.last else {
            return UpNext(episode: first, kind: .start)
        }
        if !anchor.isWatched, anchor.positionSecs > 0 {
            return UpNext(episode: anchor, kind: .resume)
        }
        guard let index = ordered.firstIndex(where: { $0.id == anchor.id }) else {
            return UpNext(episode: first, kind: .start)
        }
        if let next = ordered[(index + 1)...].first(where: { !$0.isWatched }) ?? ordered.first(where: { !$0.isWatched }) {
            return UpNext(episode: next, kind: .next)
        }
        return UpNext(episode: first, kind: .start)
    }

    /// The entry the server says the viewer looked at last. Nil when it sent no timestamps at all (an older
    /// server, or a library without them), so each caller can fall back to its own order.
    private static func mostRecentlyViewed(_ episodes: [PlexMetadata]) -> PlexMetadata? {
        guard episodes.contains(where: { $0.lastViewedAt != nil }) else { return nil }
        return episodes.max { ($0.lastViewedAt ?? 0) < ($1.lastViewedAt ?? 0) }
    }
}
