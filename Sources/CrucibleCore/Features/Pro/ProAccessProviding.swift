import Foundation

/// Why the store could not do what was asked, reduced to what the screens can act on.
package struct ProStoreFailure: Equatable, Sendable {
    package enum Reason: Equatable, Sendable {
        case offline
        case storeUnavailable
        case notAllowed
        case unknown
    }

    package var reason: Reason
    package var detail: String

    package init(_ reason: Reason, detail: String = "") {
        self.reason = reason
        self.detail = detail
    }
}

package enum ProPurchaseOutcome: Equatable, Sendable {
    case purchased
    case cancelled
    case pending
    case alreadyOwned
    case failed(ProStoreFailure)
}

package enum ProRestoreOutcome: Equatable, Sendable {
    case restored
    case nothingToRestore
    case failed(ProStoreFailure)
}

/// The store behind Crucible Pro. The RevenueCat implementation lives in CrucibleStore, which only the
/// App Store builds link; source builds use `UnlockedProAccess`, and UI tests use `ScriptedProAccess`.
package protocol ProAccessProviding: Sendable {
    /// False for builds that are not sold through the App Store: there is nothing to buy or restore.
    var isStoreBacked: Bool { get }

    /// What the store knew at the last launch, answered without the network.
    func cachedStatus() async -> ProStatus

    /// Asks the store for the current status. `nil` when it could not be reached; the cached status stays valid.
    func refreshStatus() async -> ProStatus?

    /// Every later change of the status: a purchase, a renewal, an expiry, a refund, a family member's purchase.
    func statusUpdates() -> AsyncStream<ProStatus>

    func loadOffers() async throws -> [ProOffer]

    func purchase(offerID: String) async -> ProPurchaseOutcome

    func restore() async -> ProRestoreOutcome

    /// Where an active subscription is managed, when the store can say.
    func managementURL() async -> URL?
}

package enum ProOffersError: Error, Equatable, Sendable {
    case offline
    case storeUnavailable
    case noOffers
}
