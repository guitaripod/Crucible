import Foundation

/// Fetches what the Home hubs leave out of a Top Shelf card: the full metadata of each picked title (media streams, cast,
/// trailers), its show's for an episode, and the episode after a Continue Watching episode. The requests run together
/// and whatever has not arrived by the deadline is left out, so a slow server makes the cards plainer, never late.
package enum TopShelfDetailsLoader {
    static let deadline: Duration = .seconds(10)

    package static func load(
        for picks: [TopShelfBuilder.Pick],
        api: APIClient,
        machineIdentifier: String,
        now: Date = Date()
    ) async -> [String: TopShelfBuilder.Details] {
        let collected = Collected()
        let titles = Set(picks.map(\.item.id))
        let shows = Set(picks.filter { $0.item.mediaType == "episode" }.compactMap(\.item.grandparentRatingKey))
        let continuing = picks.filter { $0.kind == .continueWatching && $0.item.mediaType == "episode" }.map(\.item)
        await withTaskGroup(of: Void.self) { race in
            race.addTask {
                await withTaskGroup(of: Void.self) { fetches in
                    for key in titles.union(shows) {
                        fetches.addTask {
                            guard let metadata = await metadata(key, api: api, machineIdentifier: machineIdentifier, now: now) else { return }
                            await collected.store(metadata, for: key)
                        }
                    }
                    for episode in continuing {
                        fetches.addTask {
                            guard let next = await nextEpisode(after: episode, api: api) else { return }
                            await collected.store(next: next, after: episode.id)
                        }
                    }
                }
            }
            race.addTask { try? await Task.sleep(for: deadline) }
            await race.next()
            race.cancelAll()
        }
        return await collected.details(for: picks)
    }

    /// The title's full metadata, from memory while it is fresh: what the Top Shelf reads from it (cast, genres, streams,
    /// trailers) does not change between two returns to the front.
    private static func metadata(_ key: String, api: APIClient, machineIdentifier: String, now: Date) async -> PlexMetadata? {
        let cacheKey = "\(machineIdentifier)/\(key)"
        if let cached = await TopShelfMetadataCache.shared.metadata(for: cacheKey, now: now) { return cached }
        guard let metadata = try? await api.requestContainer(.metadata(ratingKey: key)).Metadata?.first else { return nil }
        await TopShelfMetadataCache.shared.store(metadata, for: cacheKey, now: now)
        return metadata
    }

    /// The next episode in the season, else the first episode of the next season.
    private static func nextEpisode(after episode: PlexMetadata, api: APIClient) async -> PlexMetadata? {
        if let season = episode.parentRatingKey,
           let episodes = try? await api.requestContainer(.children(ratingKey: season)).Metadata,
           let next = TopShelfBuilder.episode(after: episode, in: episodes) {
            return next
        }
        guard let show = episode.grandparentRatingKey, let number = episode.parentIndex,
              let seasons = try? await api.requestContainer(.children(ratingKey: show)).Metadata,
              let season = TopShelfBuilder.season(after: number, in: seasons),
              let episodes = try? await api.requestContainer(.children(ratingKey: season.id)).Metadata else { return nil }
        return episodes.filter { $0.mediaType == "episode" }.min { ($0.index ?? .max) < ($1.index ?? .max) }
    }

    private actor Collected {
        private var metadata: [String: PlexMetadata] = [:]
        private var next: [String: PlexMetadata] = [:]

        func store(_ item: PlexMetadata, for key: String) {
            metadata[key] = item
        }

        func store(next item: PlexMetadata, after key: String) {
            next[key] = item
        }

        func details(for picks: [TopShelfBuilder.Pick]) -> [String: TopShelfBuilder.Details] {
            var details = [String: TopShelfBuilder.Details]()
            for pick in picks {
                details[pick.item.id] = TopShelfBuilder.Details(
                    item: metadata[pick.item.id],
                    show: pick.item.grandparentRatingKey.flatMap { metadata[$0] },
                    next: next[pick.item.id]
                )
            }
            return details
        }
    }
}

/// Full metadata of recent Top Shelf titles, per server, for a few hours.
package actor TopShelfMetadataCache {
    package static let shared = TopShelfMetadataCache()
    static let lifetime: TimeInterval = 6 * 3600
    static let capacity = 64

    private var entries: [String: (metadata: PlexMetadata, storedAt: Date)] = [:]

    func metadata(for key: String, now: Date) -> PlexMetadata? {
        guard let entry = entries[key], now.timeIntervalSince(entry.storedAt) < Self.lifetime else { return nil }
        return entry.metadata
    }

    func store(_ metadata: PlexMetadata, for key: String, now: Date) {
        entries[key] = (metadata, now)
        guard entries.count > Self.capacity else { return }
        let oldest = entries.sorted { $0.value.storedAt < $1.value.storedAt }.prefix(entries.count - Self.capacity).map(\.key)
        oldest.forEach { entries.removeValue(forKey: $0) }
    }

    package func removeAll() {
        entries.removeAll()
    }
}
