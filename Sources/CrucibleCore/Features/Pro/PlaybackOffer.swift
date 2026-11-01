import Foundation

/// When a film or episode watched to the end offers Crucible Pro (decision D22, which removed the free trial). The app's entry
/// installs `noteValue` and `noteOffered` from MidgarKit's offer policy through `MidgarProAccess.installPlaybackOffer`; until
/// then, as in tests, previews and source builds, nothing is offered.
@MainActor
package enum PlaybackOffer {
    package static var noteValue: (_ isOwned: Bool) -> Bool = { _ in false }
    package static var noteOffered: () -> Void = {}

    /// Counts a finished item and reports whether to offer Pro now. Only a store-backed install outside the demo, whose store
    /// has answered, counts: the demo unlocks everything without owning it, and the policy remembers an owner for good.
    package static func noteFinishedItem(access: ProAccess = .shared, demo: DemoMode = .shared) -> Bool {
        guard access.isStoreBacked, !demo.isActive, access.status != .unknown else { return false }
        return noteValue(access.status.isPro)
    }
}
