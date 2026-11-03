import Foundation

/// The shows the viewer is watching right now: any show with an episode finished on this device in the last two months, and
/// the shows on Home's Continue Watching and Up Next rows. New episodes of these are worth a notification.
@MainActor
package enum FollowedShows {
    package static let lookBack: TimeInterval = 60 * 86_400

    package static func current(now: Date = Date(), ledger: FinishedTitlesLedger = .shared) -> Set<String> {
        var shows = Set(ledger.followedShows(since: now.addingTimeInterval(-lookBack)).compactMap(\.showRatingKey))
        if let snapshot = HomeSnapshotStore.loadSync(), snapshot.machineIdentifier == ServerBootstrap.savedMachineIdentifier {
            shows.formUnion(snapshot.cards.filter { $0.bucket != HomeBucket.recentlyAdded.rawValue }.compactMap(\.grandparentRatingKey))
        }
        return shows
    }
}
