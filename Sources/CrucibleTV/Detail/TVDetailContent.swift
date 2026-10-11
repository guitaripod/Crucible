import CrucibleCore
import UIKit

/// One button in a detail screen's action row. Its `kind` is the stable identity, so a refreshed
/// title or menu reconfigures the focused button in place instead of replacing it.
struct TVDetailAction {
    enum Kind: String, Hashable, Sendable {
        case primary
        case startOver
        case watched
        case audio
        case subtitles
        case goToShow
        case nextEpisode
    }

    enum Appearance: Sendable {
        case primary
        case glass
    }

    var kind: Kind
    var title: String
    var symbol: String?
    var appearance: Appearance = .glass
    var isEnabled = true
    var menu: UIMenu?
    var accessibilityLabel: String?
    var handler: @MainActor () -> Void = {}
}

/// Everything a detail screen shows, as plain values. The screens map their models onto it; the
/// base class turns it into sections, so movie, episode and show detail share one layout.
struct TVDetailContent {
    /// Where the selected season's episodes stand: shown, still being fetched, or not fetchable.
    enum EpisodesState: Equatable, Sendable {
        case loaded
        case loading
        case failed
    }

    var artwork: DetailArtwork
    var header: TVHeroInfo
    var synopsis: String?
    var synopsisTitle: String
    var actions: [TVDetailAction]
    var seasons: [TVChipItem] = []
    var episodesHeader: TVSectionHeader?
    var episodes: [TVCardItem] = []
    var showsEpisodes = false
    var episodesState = EpisodesState.loaded
    var cast: [TVCardItem] = []
    var related: [TVCardItem] = []
    var facts: [DetailFact] = []
}

/// Maps Plex models onto the card family and the hero block.
@MainActor
enum TVDetailMapping {
    static func heroInfo(_ info: DetailHeroInfo, progress: Double?, synopsis: String? = nil) -> TVHeroInfo {
        var parts = info.meta.leading
        if let star = info.meta.star { parts.append("★ \(star)") }
        parts.append(contentsOf: info.meta.trailing)
        return TVHeroInfo(
            eyebrow: info.eyebrow,
            title: info.title,
            metaParts: parts,
            badges: info.badges,
            synopsis: synopsis,
            progress: progress
        )
    }

    static func people(_ roles: [PlexRole]) -> [TVCardItem] {
        roles.enumerated().map { index, role in
            TVCardItem(
                id: "cast.\(index)",
                artworkPath: role.thumb,
                title: role.tag ?? "",
                subtitle: role.role,
                placeholderSymbol: "person.fill"
            )
        }
    }

    static func related(_ items: [PlexMetadata]) -> [TVCardItem] {
        items.map { item in
            let subtitle: String?
            if item.mediaType == "show", let count = item.childCount, count > 0 {
                subtitle = count == 1 ? "1 season" : "\(count) seasons"
            } else {
                subtitle = item.year.map(String.init)
            }
            return TVCardItem(
                id: "related.\(item.id)",
                artworkPath: item.posterPath ?? item.grandparentThumb,
                title: item.title,
                subtitle: subtitle,
                progress: item.progressPercent > 0 ? item.progressPercent : nil,
                isUnwatched: item.mediaType != "show" && !item.isWatched && item.positionSecs == 0,
                placeholderSymbol: item.mediaType == "show" ? "tv" : "film"
            )
        }
    }

    private static func eyebrow(for marker: EpisodeStatus.Marker) -> String? {
        switch marker {
        case .inProgress: "Continue"
        case .upNext: "Up Next"
        default: nil
        }
    }

    static func episode(_ episode: PlexMetadata, status: EpisodeStatus) -> TVCardItem {
        let number = status.episodeNumber.map { "\($0)  ·  " } ?? ""
        return TVCardItem(
            id: "episode.\(episode.id)",
            artworkPath: episode.thumb,
            title: number + episode.title,
            subtitle: status.metaText.isEmpty ? nil : status.metaText,
            eyebrow: eyebrow(for: status.marker),
            progress: status.progress,
            isWatched: status.isWatched,
            isDimmed: status.isWatched,
            placeholderSymbol: "tv",
            accessibilityHint: "Press and hold for more options"
        )
    }
}
