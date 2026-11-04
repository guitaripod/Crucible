import Foundation

extension DemoLibrary {
    private static let remoteWatchlist: [(guid: String, title: String, year: Int, type: String, posterOf: String)] = [
        ("plex://movie/demo-night-train", "Night Train to Nowhere", 2024, "movie", "1010"),
        ("plex://show/demo-glass-orchard", "Glass Orchard", 2023, "show", "2005"),
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
                "title": remote.title, "year": remote.year, "thumb": items[remote.posterOf]?.fields.string("thumb") ?? "",
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
}
