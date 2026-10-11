import CrucibleCore

/// Maps the shared Search models onto the design system's card data.
enum TVSearchCards {
    /// A poster card for a movie, show, season or episode; `watchedOverride` reflects a Mark Watched/Unwatched the user just made.
    static func poster(_ item: PlexMetadata, watchedOverride: Bool? = nil) -> TVCardItem {
        let model = SearchPosterModel(item: item)
        let watched = watchedOverride ?? item.isWatched
        let hasProgress = watchedOverride != true && (model.progress ?? 0) > 0
        return TVCardItem(
            id: item.id,
            artworkPath: model.posterPath,
            title: model.title,
            subtitle: model.subtitle,
            progress: watchedOverride == true ? nil : model.progress,
            isUnwatched: isPlayable(item) ? !watched && !hasProgress : false,
            isWatched: isPlayable(item) && watched,
            badgeText: model.unwatchedCount.map(String.init),
            placeholderSymbol: model.placeholderIcon
        )
    }

    /// A landscape card for an episode result: show name, "S1 E3 · Title", progress, query highlighted.
    static func episode(_ item: PlexMetadata, query: String?, watchedOverride: Bool? = nil) -> TVCardItem {
        let model = SearchEpisodeModel(item: item)
        let watched = watchedOverride ?? item.isWatched
        return TVCardItem(
            id: item.id,
            artworkPath: model.thumbPath,
            title: model.title,
            subtitle: model.subtitle,
            progress: watchedOverride == true ? nil : model.progress,
            isWatched: watched,
            placeholderSymbol: "tv",
            highlight: query
        )
    }

    static func genre(_ genre: SearchGenre) -> TVTileItem {
        let pair = GenrePalette.pair(for: genre.title)
        return TVTileItem(
            id: genre.title,
            title: genre.title,
            accessibilityHint: "Browse \(genre.title) titles",
            gradient: TVTileGradient(top: pair.end, bottom: pair.start)
        )
    }

    private static func isPlayable(_ item: PlexMetadata) -> Bool {
        SearchItemActions.isPlayable(item)
    }
}
