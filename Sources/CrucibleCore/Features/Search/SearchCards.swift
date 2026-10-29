package struct SearchPosterModel: Equatable, Sendable {
    package var posterPath: String?
    package var title = ""
    package var subtitle: String?
    package var progress: Double?
    package var placeholderIcon = "film"
    package var isUnwatched = false
    package var unwatchedCount: Int?

    /// Poster-with-caption fields for any library item. Seasons and episodes are shown as the
    /// show they belong to, since that is what the user recognises.
    package init(item: PlexMetadata) {
        switch item.mediaType {
        case "show":
            posterPath = item.thumb
            title = item.title
            subtitle = item.year.map(String.init)
            placeholderIcon = "tv"
            let unwatched = (item.leafCount ?? 0) - (item.viewedLeafCount ?? 0)
            unwatchedCount = unwatched > 0 ? unwatched : nil
        case "season":
            posterPath = item.thumb ?? item.parentThumb
            title = item.parentTitle ?? item.title
            subtitle = item.title
            placeholderIcon = "tv"
        case "episode":
            posterPath = item.grandparentThumb ?? item.thumb
            title = item.grandparentTitle ?? item.title
            subtitle = SearchFormat.episodeSubtitle(item)
            placeholderIcon = "tv"
            progress = item.progressFraction > 0 ? item.progressFraction : nil
            isUnwatched = !item.isWatched
        default:
            posterPath = item.thumb
            title = item.title
            subtitle = item.year.map(String.init)
            progress = item.progressFraction > 0 ? item.progressFraction : nil
            isUnwatched = !item.isWatched && item.progressFraction == 0
        }
    }
}

package struct SearchTopResultModel: Equatable, Sendable {
    package let posterPath: String?
    package let title: String
    package let meta: String
    package let canPlay: Bool
    package let placeholderIcon: String

    package init(item: PlexMetadata) {
        let isEpisode = item.mediaType == "episode"
        posterPath = isEpisode ? (item.grandparentThumb ?? item.thumb) : item.thumb
        title = isEpisode ? (item.grandparentTitle ?? item.title) : item.title
        meta = SearchFormat.typeLine(for: item)
        canPlay = item.mediaType != "show"
        placeholderIcon = item.mediaType == "movie" ? "film" : "tv"
    }
}

package struct SearchEpisodeModel: Equatable, Sendable {
    package let thumbPath: String?
    package let title: String
    package let subtitle: String
    package let progress: Double?

    package init(item: PlexMetadata) {
        thumbPath = item.thumb ?? item.grandparentThumb
        title = item.grandparentTitle ?? item.title
        subtitle = SearchFormat.episodeSubtitle(item)
        progress = item.progressFraction > 0 ? item.progressFraction : nil
    }
}
