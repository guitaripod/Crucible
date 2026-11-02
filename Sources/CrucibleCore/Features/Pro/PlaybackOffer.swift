import Foundation

/// What a film or episode watched to the end leads to: the Pro Week (`ProWeek`) on the first one, its end note once the week is
/// over, and otherwise Crucible Pro offered when the offer policy says so (decision D22, which removed the free trial). The app's
/// entry installs `noteValue` and `noteOffered` from MidgarKit's offer policy through `MidgarProAccess.installPlaybackOffer`;
/// until then, as in tests, previews and source builds, nothing is offered.
@MainActor
package enum PlaybackOffer {
    package static var noteValue: (_ isOwned: Bool) -> Bool = { _ in false }
    package static var noteOffered: () -> Void = {}

    package enum Outcome: Equatable, Sendable {
        /// Nothing to show.
        case nothing
        /// The Pro Week has begun and the viewer has not been told yet.
        case proWeekStarted
        /// The Pro Week is over and the viewer has not been told yet; the paywall says so.
        case proWeekEnded
        /// The offer policy says this is the moment to offer Pro.
        case offer
    }

    /// Counts a finished item and says what to show. Only a store-backed install outside the demo, whose store has answered,
    /// counts: the demo unlocks everything without owning it, and the policy remembers an owner for good. While the week runs
    /// the items still count, so the first finish after it can be the offer, but nothing is offered during it.
    package static func noteFinishedItem(access: ProAccess = .shared, demo: DemoMode = .shared) -> Outcome {
        guard access.isStoreBacked, !demo.isActive, access.status != .unknown else { return .nothing }
        if access.startProWeekIfEligible() || access.isProWeekAnnouncementDue { return .proWeekStarted }
        let isDue = noteValue(access.status.isPro)
        if access.isProWeekEndNoticeDue { return .proWeekEnded }
        guard isDue, !access.proWeekPhase.isActive else { return .nothing }
        return .offer
    }
}
