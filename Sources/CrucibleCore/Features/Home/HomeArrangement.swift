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

    /// `rows` are the rows the viewer keeps on Home: a row turned off contributes nothing, not even the hero.
    package init(buckets: HomeBuckets, rows: Set<HomeRow> = Set(HomeRow.allCases)) {
        recent = rows.contains(.recentlyAdded) ? buckets.recent : []
        let showsUpNext = rows.contains(.upNext)
        let resumable = rows.contains(.continueWatching) ? buckets.continueWatching.filter { $0.continueSecs > 0 } : []
        let nextOnly = showsUpNext ? buckets.continueWatching.filter { $0.continueSecs == 0 } : []
        let onDeck = showsUpNext ? buckets.onDeck : []
        if let first = resumable.first {
            hero = first
            heroIsContinue = true
            continueRail = Array(resumable.dropFirst())
        } else if let first = onDeck.first {
            hero = first
        }
        var seen = Set(resumable.map(\.id)).union(hero.map { [$0.id] } ?? [])
        upNext = (onDeck + nextOnly).filter { seen.insert($0.id).inserted }
    }

    package var isEmpty: Bool { hero == nil && continueRail.isEmpty && upNext.isEmpty && recent.isEmpty }

    package var heroEyebrow: String {
        heroIsContinue ? String(localized: "Continue Watching") : String(localized: "Up Next")
    }

    package func items(for bucket: HomeBucket) -> [PlexMetadata] {
        switch bucket {
        case .hero: return hero.map { [$0] } ?? []
        case .continueWatching: return continueRail
        case .upNext: return upNext
        case .recentlyAdded: return recent
        }
    }

    /// The cards of a rail when the hero cannot take focus: the hero item stays at the head of the rail
    /// it was lifted from, so every card remains reachable. `.hero` is the hero alone.
    package func shelf(for bucket: HomeBucket) -> [PlexMetadata] {
        switch bucket {
        case .hero: return items(for: .hero)
        case .continueWatching: return (heroIsContinue ? items(for: .hero) : []) + continueRail
        case .upNext: return (heroIsContinue ? [] : items(for: .hero)) + upNext
        case .recentlyAdded: return recent
        }
    }

    /// Section or eyebrow text for a bucket; the hero reads as whichever rail it was lifted from.
    package func title(for bucket: HomeBucket) -> String {
        switch bucket {
        case .hero: return heroEyebrow
        case .continueWatching: return String(localized: "Continue Watching")
        case .upNext: return String(localized: "Up Next")
        case .recentlyAdded: return String(localized: "Recently Added")
        }
    }

    /// The This Week card only shows alongside content, and only once there is watch time to show.
    package func showsWeekCard(hasWeekActivity: Bool) -> Bool {
        !isEmpty && hasWeekActivity
    }
}
