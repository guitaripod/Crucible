import Foundation

/// What the Home sections show, derived from visible, de-duplicated buckets. The hero is the first
/// Continue Watching item, else the first On Deck item; it is not repeated in the rails below, and
/// Up Next skips anything already in Continue Watching.
package struct HomeArrangement: Sendable {
    package private(set) var hero: PlexMetadata?
    package private(set) var heroIsContinue = false
    package private(set) var continueRail: [PlexMetadata] = []
    package private(set) var upNext: [PlexMetadata] = []
    package private(set) var recent: [PlexMetadata] = []

    package init() {}

    package init(buckets: HomeBuckets) {
        recent = buckets.recent
        if let first = buckets.continueWatching.first {
            hero = first
            heroIsContinue = true
            continueRail = Array(buckets.continueWatching.dropFirst())
        } else if let first = buckets.onDeck.first {
            hero = first
        }
        let excluded = Set(buckets.continueWatching.map(\.id)).union(hero.map { [$0.id] } ?? [])
        upNext = buckets.onDeck.filter { !excluded.contains($0.id) }
    }

    package var isEmpty: Bool { hero == nil && continueRail.isEmpty && upNext.isEmpty && recent.isEmpty }

    package var heroEyebrow: String {
        heroIsContinue ? "Continue Watching" : "Up Next"
    }

    package func items(for bucket: HomeBucket) -> [PlexMetadata] {
        switch bucket {
        case .hero: return hero.map { [$0] } ?? []
        case .continueWatching: return continueRail
        case .upNext: return upNext
        case .recentlyAdded: return recent
        }
    }

    /// Section or eyebrow text for a bucket; the hero reads as whichever rail it was lifted from.
    package func title(for bucket: HomeBucket) -> String {
        switch bucket {
        case .hero: return heroEyebrow
        case .continueWatching: return "Continue Watching"
        case .upNext: return "Up Next"
        case .recentlyAdded: return "Recently Added"
        }
    }

    /// The This Week card only shows alongside content, and only once there is watch time to show.
    package func showsWeekCard(hasWeekActivity: Bool) -> Bool {
        !isEmpty && hasWeekActivity
    }
}
