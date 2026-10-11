#if DEBUG
import UIKit

/// Fixture content of the design gallery. Nothing here touches the network.
enum TVGalleryFixtures {
    struct Feature {
        let card: TVCardItem
        let hero: TVHeroInfo
        let backdropPath: String
    }

    static func art(_ kind: String, _ seed: String) -> String {
        "\(TVGalleryArt.scheme)\(kind)/\(seed)"
    }

    static let continueWatching: [Feature] = [
        feature(
            id: "salt-flats", title: "Salt Flats", subtitle: "1h 12m left", progress: 0.38,
            eyebrow: "Continue Watching", meta: ["2024", "PG-13", "1h 58m", "★ 7.4"],
            badges: ["4K", "Dolby Vision", "Atmos"],
            synopsis: "Two surveyors cross the world's brightest desert to map a lake that is no longer there, and discover who has been moving the horizon."
        ),
        feature(
            id: "the-last-lighthouse", title: "The Last Lighthouse", subtitle: "S1 · E4 · 38m left", progress: 0.62,
            eyebrow: "Continue Watching", meta: ["S1 · E4", "TV-14", "52m"],
            badges: ["HDR10", "5.1"],
            synopsis: "The keeper's final winter on the rock begins with a radio call that should be impossible, and ends with a decision that cannot be undone."
        ),
        feature(
            id: "winter-orchard", title: "Winter Orchard", subtitle: "21m left", progress: 0.81,
            eyebrow: "Continue Watching", meta: ["2023", "PG", "1h 41m", "★ 8.1"],
            badges: ["4K", "Atmos"],
            synopsis: "A family returns to the orchard they sold, a week before the first frost, to settle who gets to harvest the last of the trees."
        ),
        feature(
            id: "neon-tides", title: "Neon Tides", subtitle: "S2 · E7", progress: 0.12,
            eyebrow: "Up Next", meta: ["S2 · E7", "TV-MA", "47m"],
            badges: ["Dolby Vision"],
            synopsis: "The harbour district wakes up to a power cut that is not a power cut, and the night shift has to decide whom to trust."
        ),
        feature(
            id: "ember-run", title: "Ember Run", subtitle: "Movie", progress: nil,
            eyebrow: "Recently Added", meta: ["2025", "R", "2h 04m", "★ 6.9"],
            badges: ["4K", "HDR10"],
            synopsis: "A courier with one night and a car that should not start crosses a city that is burning in all the wrong places."
        ),
    ]

    static let posters: [TVCardItem] = [
        poster("Salt Flats", "2024", unwatched: true),
        poster("The Last Lighthouse", "2 Seasons", progress: 0.62),
        poster("Winter Orchard", "2023", watched: true),
        poster("Neon Tides", "3 Seasons", unwatched: true, badge: "NEW"),
        poster("Ember Run", "2025"),
        poster("Paper Moons", "2022", watched: true),
        poster("Quiet Harbor", "2021"),
        poster("Glass City", "2024", unwatched: true),
        poster("Hollow Crown", "1 Season"),
    ]

    static let gridPosters: [TVCardItem] = (posters + posters.prefix(3).map { item -> TVCardItem in
        var copy = item
        copy.id += "-again"
        return copy
    })

    static let episodes: [TVCardItem] = [
        TVCardItem(id: "ep1", artworkPath: art("backdrop", "orchard-ep1"), title: "1  ·  The First Frost", subtitle: "46m", isWatched: true, isDimmed: true, placeholderSymbol: "tv"),
        TVCardItem(id: "ep2", artworkPath: art("backdrop", "orchard-ep2"), title: "2  ·  What the Bees Know", subtitle: "52m", eyebrow: "Continue", progress: 0.45, placeholderSymbol: "tv"),
        TVCardItem(id: "ep3", artworkPath: art("backdrop", "orchard-ep3"), title: "3  ·  A Ladder Against the Sky", subtitle: "49m", eyebrow: "Up Next", isUnwatched: true, placeholderSymbol: "tv"),
        TVCardItem(id: "ep4", artworkPath: art("backdrop", "orchard-ep4"), title: "4  ·  Windfall", subtitle: "51m", isUnwatched: true, placeholderSymbol: "tv"),
        TVCardItem(id: "ep5", artworkPath: art("backdrop", "orchard-ep5"), title: "5  ·  Cider", subtitle: "44m", isUnwatched: true, placeholderSymbol: "tv"),
    ]

    static let people: [TVCardItem] = [
        person("Maren Voss", "Director"),
        person("Idris Okafor", "Writer"),
        person("Linnea Hart", "Ada Brandt"),
        person("Tomas Reyes", "Jonas Keel"),
        person("Priya Nair", "Dr. Sen"),
        person("Calder Finch", "The Keeper"),
        person("Yuki Tanaka", "Mina"),
        person("Oscar Lind", "Pilot"),
    ]

    static let genres: [TVTileItem] = [
        "Drama", "Comedy", "Science Fiction", "Documentary", "Thriller", "Animation", "Romance", "Crime",
    ].map { TVTileItem(id: "genre-\($0)", title: $0) }

    static let libraries: [TVTileItem] = [
        TVTileItem(id: "lib-movies", title: "Movies", subtitle: "1,248 movies", symbol: "film"),
        TVTileItem(id: "lib-shows", title: "TV Shows", subtitle: "186 shows", symbol: "tv"),
        TVTileItem(id: "lib-docs", title: "Documentaries", subtitle: "94 titles", symbol: "globe.europe.africa"),
        TVTileItem(id: "lib-music", title: "Concerts", subtitle: "31 titles", symbol: "music.mic"),
    ]

    static let chips: [TVChipItem] = [
        TVChipItem(id: "all", title: "All", isSelected: true),
        TVChipItem(id: "unwatched", title: "Unwatched"),
        TVChipItem(id: "progress", title: "In Progress"),
        TVChipItem(id: "recent", title: "Recently Added", symbol: "clock"),
        TVChipItem(id: "favourites", title: "Favourites", symbol: "star"),
    ]

    static let rows: [TVRowItem] = [
        TVRowItem(id: "history", title: "Watch History", symbol: "clock.arrow.circlepath", accessory: .chevron),
        TVRowItem(id: "stats", title: "Statistics", subtitle: "Your year in review", symbol: "chart.bar.xaxis", accessory: .chevron),
        TVRowItem(id: "quality", title: "Streaming Quality", value: "Original", symbol: "dial.high", accessory: .chevron),
        TVRowItem(id: "skip", title: "Skip Intro", value: "On", symbol: "forward.end"),
        TVRowItem(id: "selected", title: "Local connection", symbol: "wifi", accessory: .checkmark),
        TVRowItem(id: "signout", title: "Sign Out", symbol: "rectangle.portrait.and.arrow.right", isDestructive: true),
    ]

    static func feature(for id: String) -> Feature? {
        continueWatching.first { $0.card.id == id }
    }

    private static func feature(
        id: String,
        title: String,
        subtitle: String,
        progress: Double?,
        eyebrow: String,
        meta: [String],
        badges: [String],
        synopsis: String
    ) -> Feature {
        Feature(
            card: TVCardItem(
                id: id,
                artworkPath: art("backdrop", id),
                title: title,
                subtitle: subtitle,
                progress: progress,
                placeholderSymbol: "play.rectangle"
            ),
            hero: TVHeroInfo(eyebrow: eyebrow, title: title, metaParts: meta, badges: badges, synopsis: synopsis, progress: progress),
            backdropPath: art("backdrop", id)
        )
    }

    private static func poster(_ title: String, _ subtitle: String, unwatched: Bool = false, watched: Bool = false, progress: Double? = nil, badge: String? = nil) -> TVCardItem {
        let seed = title.lowercased().replacingOccurrences(of: " ", with: "-")
        return TVCardItem(
            id: "poster-\(seed)",
            artworkPath: art("poster", seed),
            title: title,
            subtitle: subtitle,
            progress: progress,
            isUnwatched: unwatched,
            isWatched: watched,
            badgeText: badge
        )
    }

    private static func person(_ name: String, _ role: String) -> TVCardItem {
        let seed = name.lowercased().replacingOccurrences(of: " ", with: "-")
        return TVCardItem(id: "person-\(seed)", artworkPath: art("person", seed), title: name, subtitle: role, placeholderSymbol: "person.fill")
    }
}
#endif
