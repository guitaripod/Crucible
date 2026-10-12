import Foundation

/// The fictional library: the catalogue read from the bundle, the watch state the viewer changes, and the viewing history.
/// Everything is answered from memory; the watch state is also written to a small file so the demo remembers across launches.
actor DemoLibrary {
    static let accountID = 1

    let machineIdentifier: String
    let clipMilliseconds: Int

    var items: [String: DemoItem] = [:]
    var movieKeys: [String] = []
    var showKeys: [String] = []
    var episodeKeysByShow: [String: [String]] = [:]
    var sections: [DemoSection] = []
    var genreIDs: [String: Int] = [:]
    var genreTitles: [String] = []
    var onDeck: [String] = []
    var history: [DemoHistoryRow] = []
    var persisted: DemoPersistedState
    let store: DemoStateStore
    let now: Int

    init(catalogURL: URL, store: DemoStateStore, now: Date = Date()) async throws {
        let data = try Data(contentsOf: catalogURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? DemoJSON,
              let rawItems = root["items"] as? [DemoJSON] else { throw DemoLibraryError.badCatalogue }
        self.store = store
        self.now = Int(now.timeIntervalSince1970)
        machineIdentifier = root.string("machineIdentifier") ?? ""
        clipMilliseconds = (root.int("clipSeconds") ?? 30) * 1000
        persisted = store.load()
        sections = (root["sections"] as? [DemoJSON] ?? []).map {
            DemoSection(id: $0.string("id") ?? "", title: $0.string("title") ?? "", type: $0.string("type") ?? "")
        }
        for genre in root["genres"] as? [DemoJSON] ?? [] {
            guard let title = genre.string("title"), let id = Int(genre.string("id") ?? "") else { continue }
            genreIDs[title] = id
            genreTitles.append(title)
        }
        onDeck = (root["onDeck"] as? [String]) ?? []
        try loadItems(rawItems)
        linkChildren()
        history = DemoHistory.build(items: items, showKeys: showKeys, movieKeys: movieKeys, now: now)
        applyPersistedState()
        recountAll()
    }

    private func loadItems(_ rawItems: [DemoJSON]) throws {
        for raw in rawItems {
            guard let kind = DemoItem.Kind(rawValue: raw.string("kind") ?? ""), var fields = raw["fields"] as? DemoJSON else {
                throw DemoLibraryError.badCatalogue
            }
            for (ago, stamp) in [("addedAgo", "addedAt"), ("updatedAgo", "updatedAt"), ("lastViewedAgo", "lastViewedAt")] {
                if let seconds = fields.int(ago) { fields[stamp] = now - seconds }
                fields[ago] = nil
            }
            var media: DemoMediaFacts?
            if let facts = raw["media"] as? DemoJSON {
                media = DemoMediaFacts(
                    width: facts.int("width") ?? 1920,
                    height: facts.int("height") ?? 1080,
                    hdr: (facts["hdr"] as? Bool) ?? false,
                    size: facts.int("size") ?? 0
                )
            }
            let item = DemoItem(
                kind: kind,
                fields: fields,
                genres: raw["genres"] as? [String] ?? [],
                directors: raw["directors"] as? [String] ?? [],
                writers: raw["writers"] as? [String] ?? [],
                cast: raw["cast"] as? [DemoJSON] ?? [],
                related: raw["related"] as? [String] ?? [],
                media: media,
                show: raw.string("show"),
                season: raw.string("season")
            )
            let key = item.ratingKey
            items[key] = item
            switch kind {
            case .movie: movieKeys.append(key)
            case .show: showKeys.append(key)
            default: break
            }
        }
    }

    private func linkChildren() {
        for key in orderedKeys where items[key]?.kind == .season {
            if let show = items[key]?.show { items[show]?.children.append(key) }
        }
        for key in orderedKeys where items[key]?.kind == .episode {
            guard let item = items[key], let season = item.season, let show = item.show else { continue }
            items[season]?.children.append(key)
            episodeKeysByShow[show, default: []].append(key)
        }
    }

    /// Every key in catalogue order: ratingKeys are assigned in that order, so sorting them numerically restores it.
    var orderedKeys: [String] {
        items.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    }

    func item(_ key: String) -> DemoItem? {
        items[key]
    }

    func sectionItemKeys(_ sectionID: String) -> [String] {
        guard let section = sections.first(where: { $0.id == sectionID }) else { return [] }
        let pool = section.type == "movie" ? movieKeys : showKeys
        return pool.filter { items[$0]?.sectionID == Int(sectionID) }
    }

    func leafKeys(of key: String) -> [String] {
        guard let item = items[key] else { return [] }
        switch item.kind {
        case .show: return item.children.flatMap { items[$0]?.children ?? [] }
        case .season: return item.children
        default: return []
        }
    }

    private func applyPersistedState() {
        for (key, saved) in persisted.items where items[key] != nil {
            setWatchFields(key, viewCount: saved.viewCount, viewOffset: saved.viewOffset, lastViewedAt: saved.lastViewedAt)
        }
        if let saved = persisted.onDeck { onDeck = saved.filter { items[$0] != nil } }
        var nextID = (history.map(\.id).max() ?? 0) + 1
        for play in persisted.plays where items[play.ratingKey] != nil {
            history.append(DemoHistoryRow(id: nextID, ratingKey: play.ratingKey, viewedAt: play.viewedAt))
            nextID += 1
        }
    }

    func setWatchFields(_ key: String, viewCount: Int, viewOffset: Int, lastViewedAt: Int) {
        guard var item = items[key] else { return }
        item.set("viewCount", viewCount > 0 ? viewCount : nil)
        item.set("viewOffset", viewOffset > 0 ? viewOffset : nil)
        item.set("lastViewedAt", lastViewedAt > 0 ? lastViewedAt : nil)
        items[key] = item
    }

    /// Recomputes the leaf counts, watched flags and last-viewed times a season or show derives from its episodes.
    func recountAll() {
        for showKey in showKeys {
            guard var show = items[showKey] else { continue }
            var leaves = 0
            var viewed = 0
            var lastViewed = 0
            for seasonKey in show.children {
                guard var season = items[seasonKey] else { continue }
                let episodes = season.children.compactMap { items[$0] }
                let seasonViewed = episodes.filter(\.isWatched).count
                season.set("leafCount", episodes.count)
                season.set("viewedLeafCount", seasonViewed)
                season.set("viewCount", seasonViewed == episodes.count && !episodes.isEmpty ? 1 : nil)
                items[seasonKey] = season
                leaves += episodes.count
                viewed += seasonViewed
                lastViewed = max(lastViewed, episodes.map(\.lastViewedAt).max() ?? 0)
            }
            show.set("leafCount", leaves)
            show.set("viewedLeafCount", viewed)
            show.set("viewCount", leaves > 0 && viewed == leaves ? 1 : nil)
            if lastViewed > 0 { show.set("lastViewedAt", lastViewed) }
            items[showKey] = show
        }
    }

    func flush() {
        store.flush()
    }
}

enum DemoLibraryError: Error {
    case badCatalogue
    case resourcesMissing
}
