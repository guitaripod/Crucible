import Foundation

/// Pro for builds that are not sold through the App Store (source builds, sideloads, tests): everything is on,
/// there is nothing to buy, and the Pro screens stay hidden.
package final class UnlockedProAccess: ProAccessProviding {
    package let isStoreBacked = false

    package init() {}

    package func cachedStatus() async -> ProStatus { .pro(.included) }

    package func refreshStatus() async -> ProStatus? { .pro(.included) }

    package func statusUpdates() -> AsyncStream<ProStatus> { AsyncStream { $0.finish() } }

    package func loadOffers() async throws -> [ProOffer] { [] }

    package func purchase(offerID: String) async -> ProPurchaseOutcome { .alreadyOwned }

    package func restore() async -> ProRestoreOutcome { .restored }

    package func managementURL() async -> URL? { nil }
}
