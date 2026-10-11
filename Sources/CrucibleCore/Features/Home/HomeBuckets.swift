import Foundation

/// The three raw item lists Home is built from, before visibility filtering and arrangement.
package struct HomeBuckets: Sendable {
    package static let snapshotCardCap = 20

    package var continueWatching: [PlexMetadata]
    package var onDeck: [PlexMetadata]
    package var recent: [PlexMetadata]

    package init(continueWatching: [PlexMetadata] = [], onDeck: [PlexMetadata] = [], recent: [PlexMetadata] = []) {
        self.continueWatching = continueWatching
        self.onDeck = onDeck
        self.recent = recent
    }

    /// Sorts `/hubs` results into the three lists by substring of `hubIdentifier`; hubs with no
    /// items or an unrecognised identifier are skipped.
    package init(hubs: [PlexHub]?) {
        self.init()
        for hub in hubs ?? [] {
            guard let id = hub.hubIdentifier, let items = hub.Metadata, !items.isEmpty else { continue }
            let lowered = id.lowercased()
            if lowered.contains("continue") || lowered.contains("inprogress") {
                continueWatching.append(contentsOf: items)
            } else if lowered.contains("ondeck") {
                onDeck.append(contentsOf: items)
            } else if lowered.contains("recentlyadded") || lowered.contains("recent") {
                recent.append(contentsOf: items)
            }
        }
    }

    package init(snapshot: HomeSnapshot) {
        self.init()
        for card in snapshot.cards {
            let media = PlexMetadata(homeCard: card)
            switch card.bucket {
            case SnapshotCode.continueWatching: continueWatching.append(media)
            case SnapshotCode.onDeck: onDeck.append(media)
            default: recent.append(media)
            }
        }
    }

    package var count: Int { continueWatching.count + onDeck.count + recent.count }

    /// Backdrop paths a cold launch can use before the network answers, keyed by rating key.
    package static func cachedArt(in snapshot: HomeSnapshot) -> [String: String] {
        var art = [String: String]()
        for card in snapshot.cards {
            if let path = card.grandparentArt ?? card.art { art[card.ratingKey] = path }
        }
        return art
    }

    /// At most `snapshotCardCap` cards per list, carrying the artwork paths the cold launch needs.
    package func snapshotCards() -> [HomeCardSnapshot] {
        func card(_ item: PlexMetadata, _ bucket: String) -> HomeCardSnapshot {
            var card = item.homeCard(bucket: bucket)
            card.art = item.art
            card.grandparentArt = item.grandparentArt
            return card
        }
        let cap = Self.snapshotCardCap
        return continueWatching.prefix(cap).map { card($0, SnapshotCode.continueWatching) }
            + onDeck.prefix(cap).map { card($0, SnapshotCode.onDeck) }
            + recent.prefix(cap).map { card($0, SnapshotCode.recent) }
    }

    /// Drops items from libraries left out of Home, then repeats of the same item, in each list.
    package func visible(excluding excluded: Set<Int>) -> HomeBuckets {
        HomeBuckets(
            continueWatching: Self.deduped(Self.visible(continueWatching, excluding: excluded)),
            onDeck: Self.deduped(Self.visible(onDeck, excluding: excluded)),
            recent: Self.deduped(Self.visible(recent, excluding: excluded))
        )
    }

    /// Drops items from libraries left out of Home; items with no known library stay.
    package static func visible(_ items: [PlexMetadata], excluding excluded: Set<Int>) -> [PlexMetadata] {
        guard !excluded.isEmpty else { return items }
        return items.filter { item in item.librarySectionID.map { !excluded.contains($0) } ?? true }
    }

    package static func deduped(_ items: [PlexMetadata]) -> [PlexMetadata] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private enum SnapshotCode {
        static let continueWatching = "cw"
        static let onDeck = "od"
        static let recent = "ra"
    }
}
