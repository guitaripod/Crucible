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

    /// Counts a finished item and says what to show. Only a store-backed install whose store has answered counts. The demo never
    /// counts toward the offer policy, which remembers an owner for good: it unlocks everything, and while it previews the free
    /// version it only begins and ends a Pro Week of its own. While the week runs the items still count, so the first finish after
    /// it can be the offer, but nothing is offered during it.
    package static func noteFinishedItem(access: ProAccess = .shared, demo: DemoMode = .shared) -> Outcome {
        guard access.isStoreBacked, access.status != .unknown else { return .nothing }
        if demo.isActive { return demo.previewsFreeVersion ? demoProWeekNote(access) : .nothing }
        if access.startProWeekIfEligible() || access.isProWeekAnnouncementDue { return .proWeekStarted }
        let isDue = noteValue(access.status.isPro)
        if access.isProWeekEndNoticeDue { return .proWeekEnded }
        guard isDue, !access.proWeekPhase.isActive else { return .nothing }
        return .offer
    }

    /// Tells the offer policy an offer was shown. One shown in the demo is not the policy's to count.
    package static func recordOffer(demo: DemoMode = .shared) {
        guard !demo.isActive else { return }
        noteOffered()
    }

    private static func demoProWeekNote(_ access: ProAccess) -> Outcome {
        if access.startProWeekIfEligible() || access.isProWeekAnnouncementDue { return .proWeekStarted }
        return access.isProWeekEndNoticeDue ? .proWeekEnded : .nothing
    }
}
