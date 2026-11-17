import Foundation

/// When Crucible may ask for an App Store rating. MidgarKit's review policy decides (not in the first days or sessions, once a
/// version and months apart, never in the week after a failed purchase); the App Store builds install it through
/// `MidgarProAccess.installReviewMoments`, and source builds, tests and previews install nothing, so they never ask. The one reason to
/// ask is a film or episode watched to the end, outside the demo, whose fictional library is not the viewer's own.
@MainActor
package enum ReviewMoments {
    package static var noteSuccess: () -> Bool = { false }
    package static var notePrompted: () -> Void = {}
    package static var notePurchaseFailure: () -> Void = {}

    /// Counts a film or episode watched to the end and says whether to ask for a rating now.
    package static func finishedTitle(demo: DemoMode = .shared) -> Bool {
        guard !demo.isActive else { return false }
        return noteSuccess()
    }
}
