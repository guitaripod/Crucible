import Foundation

/// The demo's stand-in for Trakt: every title of the catalogue is known to it under an IMDb id made from its rating key, so
/// scrobbling, ratings, check-ins and the ratings strip all work without a Trakt account.
extension DemoLibrary {
    /// The IMDb id the demo gives a title that carries no outside id of its own.
    static func demoIMDb(_ key: String) -> String { "imdb://tt99\(key)" }

    /// The catalogue title Trakt would find for an outside id, with the kind Trakt calls it.
    func traktItem(idType: String, id: String) -> DemoItem? {
        if idType == "imdb", id.hasPrefix("tt99"), let item = items[String(id.dropFirst(4))] { return item }
        let guid = "\(idType)://\(id)"
        return items.values.first { item in
            (item.fields["Guid"] as? [DemoJSON])?.contains { $0.string("id") == guid } == true
        }
    }

    func traktIDs(_ item: DemoItem) -> DemoJSON {
        var ids: DemoJSON = ["trakt": Int(item.ratingKey) ?? 0, "slug": "demo-\(item.ratingKey)", "imdb": "tt99\(item.ratingKey)"]
        for guid in (item.fields["Guid"] as? [DemoJSON]) ?? [] {
            let parts = (guid.string("id") ?? "").components(separatedBy: "://")
            guard parts.count == 2, let number = Int(parts[1]) else { continue }
            if parts[0] == "tvdb" || parts[0] == "tmdb" { ids[parts[0]] = number }
        }
        return ids
    }

    func traktSearch(idType: String, id: String, kind: String) -> DemoResponse {
        guard let item = traktItem(idType: idType, id: id), item.kind.rawValue == kind else { return .json([] as [Any]) }
        var hit: DemoJSON = ["type": kind, "score": 1000]
        hit[kind] = ["title": item.title, "year": item.fields.int("year") ?? 0, "ids": traktIDs(item)] as DemoJSON
        if kind == "episode", let show = item.show.flatMap({ items[$0] }) {
            hit["episode"] = ["season": item.fields.int("parentIndex") ?? 0, "number": item.fields.int("index") ?? 0, "title": item.title, "ids": traktIDs(item)] as DemoJSON
            hit["show"] = ["title": show.title, "ids": traktIDs(show)] as DemoJSON
        }
        return .json([hit])
    }

    func traktEpisodeKey(show showID: String, season: Int, number: Int) -> String? {
        (episodeKeysByShow[showID] ?? []).first { key in
            items[key]?.fields.int("parentIndex") == season && items[key]?.fields.int("index") == number
        }
    }

    func traktEpisode(show showID: String, season: Int, number: Int) -> DemoResponse {
        guard let key = traktEpisodeKey(show: showID, season: season, number: number), let episode = items[key] else { return .notFound() }
        return .json(["season": season, "number": number, "title": episode.title, "ids": traktIDs(episode)] as DemoJSON)
    }

    /// Scores made from the title's own audience rating, so each title has steady, believable numbers.
    func traktRatings(_ key: String) -> DemoResponse {
        guard let item = items[key] else { return .notFound() }
        let audience = item.fields.double("audienceRating") ?? item.show.flatMap { items[$0]?.fields.double("audienceRating") } ?? 7.5
        let seed = (Int(key) ?? 1) % 97
        var ratings: DemoJSON = [
            "trakt": ["rating": min(9.8, audience + 0.4), "votes": 1_800 + seed * 137] as DemoJSON,
            "imdb": ["rating": audience, "votes": 40_000 + seed * 2_311, "link": "https://www.imdb.com/"] as DemoJSON,
            "tmdb": ["rating": max(1, audience - 0.2), "votes": 900 + seed * 41] as DemoJSON,
        ]
        if item.kind == .movie {
            ratings["rotten_tomatoes"] = ["rating": min(99, Int(audience * 11) - seed % 9), "state": "fresh"] as DemoJSON
            ratings["metascore"] = ["rating": min(95, Int(audience * 9) + seed % 7)] as DemoJSON
            ratings["letterboxd"] = ["rating": (audience / 2 * 10).rounded() / 10] as DemoJSON
        }
        return .json(ratings)
    }

    /// The viewer's Trakt history: the newest plays of the demo server, as Crucible would have sent them, and plays from
    /// elsewhere the server never saw (a show and two films on streaming services, one more episode of a library show), so
    /// Statistics' Everything has something of its own to add.
    func traktHistory() -> DemoResponse {
        let iso = ISO8601DateFormatter()
        var entries: [DemoJSON] = []
        let newest = history.sorted { $0.viewedAt > $1.viewedAt }.prefix(6)
        for row in newest {
            guard let item = items[row.ratingKey] else { continue }
            let watched = iso.string(from: Date(timeIntervalSince1970: TimeInterval(row.viewedAt + 300)))
            if item.kind == .episode, let show = item.show.flatMap({ items[$0] }) {
                entries.append([
                    "id": 500_000 + row.id, "watched_at": watched, "action": "scrobble", "type": "episode",
                    "episode": ["season": item.fields.int("parentIndex") ?? 0, "number": item.fields.int("index") ?? 0, "title": item.title, "ids": traktIDs(item), "runtime": 42] as DemoJSON,
                    "show": ["title": show.title, "year": show.fields.int("year") ?? 0, "ids": traktIDs(show)] as DemoJSON,
                ])
            } else if item.kind == .movie {
                entries.append([
                    "id": 500_000 + row.id, "watched_at": watched, "action": "scrobble", "type": "movie",
                    "movie": ["title": item.title, "year": item.fields.int("year") ?? 0, "ids": traktIDs(item), "runtime": 110] as DemoJSON,
                ])
            }
        }
        let now = Date().timeIntervalSince1970
        for episode in 1...6 {
            entries.append([
                "id": 600_000 + episode, "watched_at": iso.string(from: Date(timeIntervalSince1970: now - Double(episode) * 2.5 * 86_400 - 7_200)),
                "action": "watch", "type": "episode",
                "episode": ["season": 1, "number": 7 - episode, "title": "Furrow \(7 - episode)", "ids": ["trakt": 900_100 + episode] as DemoJSON, "runtime": 51] as DemoJSON,
                "show": ["title": "The Long Field", "year": 2025, "ids": ["trakt": 900_001] as DemoJSON, "genres": ["drama", "mystery"]] as DemoJSON,
            ])
        }
        for (index, film) in [("Paper Lanterns", 2024, 112, "romance"), ("Night Ferry", 2023, 98, "thriller")].enumerated() {
            entries.append([
                "id": 610_000 + index, "watched_at": iso.string(from: Date(timeIntervalSince1970: now - Double(index + 1) * 9 * 86_400)),
                "action": "watch", "type": "movie",
                "movie": ["title": film.0, "year": film.1, "ids": ["trakt": 900_200 + index] as DemoJSON, "runtime": film.2, "genres": [film.3]] as DemoJSON,
            ])
        }
        if let row = newest.first(where: { items[$0.ratingKey]?.kind == .episode }), let item = items[row.ratingKey], let show = item.show.flatMap({ items[$0] }) {
            entries.append([
                "id": 620_000, "watched_at": iso.string(from: Date(timeIntervalSince1970: TimeInterval(row.viewedAt) - 4 * 86_400)),
                "action": "watch", "type": "episode",
                "episode": ["season": (item.fields.int("parentIndex") ?? 1) + 5, "number": 1, "title": "Away From Home", "ids": ["trakt": 900_300] as DemoJSON, "runtime": 44] as DemoJSON,
                "show": ["title": show.title, "year": show.fields.int("year") ?? 0, "ids": traktIDs(show)] as DemoJSON,
            ])
        }
        return .json(entries)
    }

    /// Approves the device code on the second ask, as a viewer approving on their phone would.
    func traktDevicePoll() -> DemoResponse {
        traktPolls += 1
        guard traktPolls >= 2 else { return .empty(400) }
        traktPolls = 0
        return .json([
            "access_token": "demo-trakt", "refresh_token": "demo-trakt-refresh", "token_type": "bearer",
            "expires_in": 7 * 86_400, "scope": "public", "created_at": Int(Date().timeIntervalSince1970),
        ] as DemoJSON)
    }
}
