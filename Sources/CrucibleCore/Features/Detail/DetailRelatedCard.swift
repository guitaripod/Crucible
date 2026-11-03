import Foundation

/// One title of a "More Like This" shelf, reduced to what a poster card shows: artwork, title, the
/// year or season count, progress and whether it is still unwatched. iPhone and Apple TV build their
/// cards from it, so the two never disagree about what a related title says.
package struct DetailRelatedCard: Equatable, Sendable {
    package let id: String
    package let posterPath: String?
    package let title: String
    package let subtitle: String?
    package let progress: Double?
    package let isUnwatched: Bool
    package let isShow: Bool

    package init(item: PlexMetadata) {
        id = item.id
        let isEpisode = item.mediaType == "episode"
        posterPath = isEpisode ? (item.grandparentThumb ?? item.posterPath) : (item.posterPath ?? item.grandparentThumb)
        title = item.title
        isShow = item.mediaType == "show"
        if isShow, let count = item.childCount, count > 0 {
            subtitle = count == 1 ? String(localized: "1 season") : String(localized: "\(count) seasons")
        } else if isEpisode {
            let parts = [item.grandparentTitle, DetailFormat.episodeCode(season: item.parentIndex, episode: item.index)].compactMap { $0 }
            subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
        } else {
            subtitle = item.year.map(String.init)
        }
        progress = item.progressPercent > 0 ? item.progressPercent : nil
        isUnwatched = !isShow && !item.isWatched && item.positionSecs == 0
    }
}
