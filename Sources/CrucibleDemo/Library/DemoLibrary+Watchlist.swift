import Foundation

extension DemoLibrary {
    private static let remoteWatchlist: [(guid: String, title: String, year: Int, type: String, tmdbID: Int)] = [
        ("plex://movie/demo-night-train", "Night Train to Nowhere", 2024, "movie", 980_001),
        ("plex://show/demo-glass-orchard", "Glass Orchard", 2023, "show", 980_002),
    ]

    static let defaultWatchlist = ["plex://movie/1001", "plex://movie/demo-night-train", "plex://movie/1006", "plex://show/demo-glass-orchard"]

    /// The account's watchlist: titles the server has, which open as they are, and titles it does not have.
    func watchlistResponse() -> DemoResponse {
        let metadata = watchlistGuids.compactMap { guid -> DemoJSON? in
            if let key = items.first(where: { $0.value.fields.string("guid") == guid })?.key, let json = render(key) {
                return json
            }
            guard let remote = Self.remoteWatchlist.first(where: { $0.guid == guid }) else { return nil }
            let discoverKey = guid.split(separator: "/").last.map(String.init) ?? guid
            return [
                "ratingKey": discoverKey, "key": "/library/metadata/\(discoverKey)", "guid": guid, "type": remote.type,
                "title": remote.title, "year": remote.year, "thumb": Self.remotePoster(remote.tmdbID),
                "summary": "A title Plex knows that this server does not have.",
            ]
        }
        return .container(["size": metadata.count, "totalSize": metadata.count, "offset": 0, "Metadata": metadata])
    }

    func changeWatchlist(discoverKey: String, adding: Bool) -> DemoResponse {
        let known = Set(items.values.compactMap { $0.fields.string("guid") } + Self.remoteWatchlist.map(\.guid))
        let guid = known.first { $0.hasSuffix("/\(discoverKey)") } ?? "plex://movie/\(discoverKey)"
        watchlistGuids.removeAll { $0 == guid }
        if adding { watchlistGuids.insert(guid, at: 0) }
        return .empty()
    }

    private static let catalogShow = (key: "demo-glass-orchard", title: "Glass Orchard", seasons: 3, episodes: 8)

    /// Plex's catalogue of Glass Orchard, the watchlisted show this server does not have: its seasons, and each season's
    /// episodes with their air dates, so Home has a season out now to show.
    func catalogChildren(_ key: String) -> DemoResponse? {
        let show = Self.catalogShow
        let metadata: [DemoJSON]
        if key == show.key {
            metadata = (1...show.seasons).map { season in
                [
                    "ratingKey": "\(show.key)-s\(season)", "key": "/library/metadata/\(show.key)-s\(season)/children", "type": "season",
                    "title": "Season \(season)", "index": season, "parentTitle": show.title, "leafCount": show.episodes,
                ]
            }
        } else if key.hasPrefix("\(show.key)-s"), let season = Int(key.dropFirst(show.key.count + 2)), (1...show.seasons).contains(season) {
            metadata = (1...show.episodes).map { episode in
                [
                    "ratingKey": "\(show.key)-s\(season)e\(episode)", "type": "episode", "title": "Episode \(episode)",
                    "index": episode, "parentIndex": season, "grandparentTitle": show.title,
                    "originallyAvailableAt": Self.catalogAirDate(season: season, episode: episode, now: Date(timeIntervalSince1970: TimeInterval(now))),
                ]
            }
        } else {
            return nil
        }
        return .container(["size": metadata.count, "totalSize": metadata.count, "offset": 0, "Metadata": metadata])
    }

    /// The earlier seasons ran weekly from March of 2023 and 2024; the last one opened four days ago with two episodes and
    /// goes on weekly. Dates are Gregorian days where the viewer is, as Plex's catalogue gives them.
    static func catalogAirDate(season: Int, episode: Int, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date: Date
        if season == catalogShow.seasons {
            date = calendar.date(byAdding: .day, value: -4 + max(0, episode - 2) * 7, to: now) ?? now
        } else {
            let premiere = calendar.date(from: DateComponents(year: 2022 + season, month: 3, day: 14)) ?? now
            date = calendar.date(byAdding: .day, value: (episode - 1) * 7, to: premiere) ?? premiere
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// Seasons Plex's catalogue lists for library shows that the demo server lacks: Dry Season, watched to the end, has a
    /// second season airing weekly since nine days ago, and Meridian a fifth that finished airing.
    private static let catalogueAdditions: [String: (season: Int, episodes: Int, firstAiredDaysAgo: Int)] = [
        "2006": (2, 6, 9),
        "2003": (5, 8, 70),
    ]

    /// The stand-in catalogue's answer for a library show or one of its seasons: what the server has, with the seasons it
    /// lacks after it. Nil for anything else.
    func libraryCatalogueChildren(_ key: String) -> DemoResponse? {
        let metadata: [DemoJSON]
        if let show = items[key], show.kind == .show {
            var seasons = show.children.compactMap { items[$0] }.filter { $0.kind == .season }.map { season -> DemoJSON in
                ["ratingKey": season.ratingKey, "type": "season", "title": season.title, "index": season.fields.int("index") ?? 0, "leafCount": season.children.count]
            }
            if let added = Self.catalogueAdditions[key] {
                seasons.append([
                    "ratingKey": Self.addedSeasonKey(key, added.season), "type": "season", "title": "Season \(added.season)",
                    "index": added.season, "leafCount": added.episodes,
                    "originallyAvailableAt": Self.day(daysAgo: added.firstAiredDaysAgo, now: Date(timeIntervalSince1970: TimeInterval(now))),
                ])
            }
            metadata = seasons
        } else if let season = items[key], season.kind == .season {
            metadata = season.children.compactMap { items[$0] }.map { episode in
                ["ratingKey": episode.ratingKey, "type": "episode", "title": episode.title, "index": episode.fields.int("index") ?? 0, "parentIndex": episode.fields.int("parentIndex") ?? 0]
            }
        } else if let (show, added) = Self.catalogueAdditions.first(where: { Self.addedSeasonKey($0.key, $0.value.season) == key }).map({ ($0.key, $0.value) }) {
            let today = Date(timeIntervalSince1970: TimeInterval(now))
            metadata = (1...added.episodes).map { episode in
                [
                    "ratingKey": "\(Self.addedSeasonKey(show, added.season))e\(episode)", "type": "episode", "title": "Episode \(episode)",
                    "index": episode, "parentIndex": added.season,
                    "originallyAvailableAt": Self.day(daysAgo: added.firstAiredDaysAgo - (episode - 1) * 7, now: today),
                    "summary": "An episode the demo server does not have yet.",
                ]
            }
        } else {
            return nil
        }
        return .container(["size": metadata.count, "totalSize": metadata.count, "offset": 0, "Metadata": metadata])
    }

    private static func addedSeasonKey(_ show: String, _ season: Int) -> String { "\(show)-catalogue-s\(season)" }

    /// The Gregorian day `daysAgo` before `now` where the viewer is, as Plex's catalogue writes air dates.
    private static func day(daysAgo: Int, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
