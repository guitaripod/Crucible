import Foundation

/// What a library poster shows, independent of how a platform draws it.
package struct LibraryPoster: Equatable, Sendable {
    package let posterPath: String?
    package let title: String
    package let subtitle: String?
    package let placeholderIcon: String
    package let progress: Double?
    package let isUnwatched: Bool
    package let unwatchedCount: Int?

    private init(
        posterPath: String?,
        title: String,
        subtitle: String?,
        placeholderIcon: String,
        progress: Double? = nil,
        isUnwatched: Bool = false,
        unwatchedCount: Int? = nil
    ) {
        self.posterPath = posterPath
        self.title = title
        self.subtitle = subtitle
        self.placeholderIcon = placeholderIcon
        self.progress = progress
        self.isUnwatched = isUnwatched
        self.unwatchedCount = unwatchedCount
    }

    /// A movie poster carries progress or an unwatched dot; a show poster carries its unwatched episode count.
    package init(grid item: PlexMetadata, kind: LibraryGridKind) {
        let year = item.year.map(String.init)
        switch kind {
        case .movie:
            let progress = item.progressPercent
            self.init(
                posterPath: item.thumb ?? item.grandparentThumb,
                title: item.title,
                subtitle: year,
                placeholderIcon: kind.placeholderIcon,
                progress: progress > 0 ? progress : nil,
                isUnwatched: !item.isWatched && progress <= 0
            )
        case .show:
            let unwatched = (item.leafCount ?? 0) - (item.viewedLeafCount ?? 0)
            self.init(
                posterPath: item.thumb ?? item.grandparentThumb,
                title: item.title,
                subtitle: year,
                placeholderIcon: kind.placeholderIcon,
                unwatchedCount: unwatched > 0 ? unwatched : nil
            )
        }
    }

    /// A Recently Watched card. A show library's cards stand for the series but carry the episode last played.
    package init(recent item: PlexMetadata, kind: LibraryGridKind) {
        let when = Formatters.unixRelativeDate(item.viewedAt)
        switch kind {
        case .movie:
            self.init(
                posterPath: item.thumb ?? item.grandparentThumb,
                title: item.title,
                subtitle: when,
                placeholderIcon: kind.placeholderIcon
            )
        case .show:
            let detail = [Formatters.episodeCode(item.parentIndex, item.index), when].compactMap { $0 }.joined(separator: " · ")
            self.init(
                posterPath: item.grandparentThumb ?? item.thumb,
                title: item.grandparentTitle ?? item.title,
                subtitle: detail.isEmpty ? nil : detail,
                placeholderIcon: kind.placeholderIcon
            )
        }
    }

    package init(folderItem item: PlexMetadata) {
        let episodic = item.mediaType == "show" || item.mediaType == "episode"
        self.init(
            posterPath: item.thumb ?? item.grandparentThumb,
            title: item.title,
            subtitle: LibraryFormat.folderMediaSubtitle(item),
            placeholderIcon: episodic ? "tv" : "film"
        )
    }
}

/// One entry of a poster's long-press menu. The platform draws it and performs the action; downloads
/// are not part of it because only some platforms offer them.
package struct LibraryItemAction: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        case play
        case playFromBeginning
        case setWatched(Bool)
        case goToShow(String)
        case viewDetails
    }

    package let kind: Kind
    package let title: String
    package let symbol: String

    /// A movie poster: play, restart, both watched directions and details. A show poster: both
    /// directions for the whole series and details.
    package static func grid(for item: PlexMetadata, kind: LibraryGridKind) -> [LibraryItemAction] {
        var actions = [LibraryItemAction]()
        switch kind {
        case .movie:
            actions.append(LibraryItemAction(kind: .play, title: item.isResumable ? "Resume" : "Play", symbol: "play.fill"))
            if item.isResumable {
                actions.append(LibraryItemAction(kind: .playFromBeginning, title: "Play from Beginning", symbol: "gobackward"))
            }
            actions.append(LibraryItemAction(kind: .setWatched(true), title: "Mark Watched", symbol: "checkmark.circle"))
            actions.append(LibraryItemAction(kind: .setWatched(false), title: "Mark Unwatched", symbol: "eye.slash"))
        case .show:
            actions.append(LibraryItemAction(kind: .setWatched(true), title: "Mark Show Watched", symbol: "checkmark.circle"))
            actions.append(LibraryItemAction(kind: .setWatched(false), title: "Mark Show Unwatched", symbol: "eye.slash"))
        }
        actions.append(LibraryItemAction(kind: .viewDetails, title: "View Details", symbol: "info.circle"))
        return actions
    }

    /// A Recently Watched card: go to the series (show libraries), play again, both watched
    /// directions and details.
    package static func recent(for item: PlexMetadata, kind: LibraryGridKind) -> [LibraryItemAction] {
        var actions = [LibraryItemAction]()
        if kind == .show, let showKey = item.grandparentRatingKey {
            actions.append(LibraryItemAction(kind: .goToShow(showKey), title: "Go to Show", symbol: "tv"))
        }
        actions.append(LibraryItemAction(kind: .play, title: "Play Again", symbol: "play.fill"))
        actions.append(LibraryItemAction(kind: .setWatched(true), title: "Mark Watched", symbol: "checkmark.circle"))
        actions.append(LibraryItemAction(kind: .setWatched(false), title: "Mark Unwatched", symbol: "eye.slash"))
        actions.append(LibraryItemAction(
            kind: .viewDetails,
            title: kind == .show ? "Episode Details" : "View Details",
            symbol: "info.circle"
        ))
        return actions
    }
}

/// Where opening a library card leads.
package enum LibraryDestination: Equatable, Sendable {
    case show(ratingKey: String)
    case media(PlexMetadata)

    /// A grid or folder entry opens the show for a show or one of its seasons, and the item itself for
    /// anything playable. Entries that have no screen (collections, playlists, photos, music) open nothing.
    package init?(browsing item: PlexMetadata) {
        switch item.mediaType {
        case "show":
            self = .show(ratingKey: item.id)
        case "season":
            self = .show(ratingKey: item.parentRatingKey ?? item.id)
        case "collection", "playlist", "photo", "photoalbum", "artist", "album", "track":
            return nil
        default:
            self = .media(item)
        }
    }

    /// A Recently Watched card opens the series for a show library, and the film for a movie library.
    package init(recent item: PlexMetadata, kind: LibraryGridKind) {
        switch kind {
        case .movie: self = .media(item)
        case .show: self = .show(ratingKey: item.grandparentRatingKey ?? item.id)
        }
    }
}
