import CrucibleCore
import Foundation
import MidgarCommerce
import MidgarCore
import StoreKit

/// Crucible Pro sold through MidgarStore: StoreKit buys and finishes, the Midgar ledger records each purchase
/// against the person's Midgar ID, and the lifetime and yearly products both grant `pro`. Everything the screens
/// need is mapped to the store-free types in CrucibleCore.
package final class MidgarProAccess: ProAccessProviding {
    package static let appID = "crucible"
    package static let bundleID = "com.guitaripod.crucible"
    package static let entitlement = "pro"
    package static let lifetimeID = "com.guitaripod.crucible.pro.lifetime"
    package static let yearlyID = "com.guitaripod.crucible.pro.yearly"
    package static let productIDs = [lifetimeID, yearlyID]

    package let isStoreBacked = true

    private let store: MidgarStore

    /// False inside an XCTest host, which must not mint a Midgar ID or reach the ledger in production.
    package static var reachesMidgarServices: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    /// Wraps a store built elsewhere, as the StoreKit tests do with a stub identity and ledger.
    package init(store: MidgarStore) {
        self.store = store
    }

    /// Creates the one store of the process. Its `Transaction.updates` listener starts here, so create it once at
    /// launch, before the first screen; the Midgar ID is minted or attached in the background.
    package static func live() -> MidgarProAccess {
        let configuration = MidgarHTTPConfiguration(appID: appID)
        let identity = MidgarIdentity(httpConfiguration: configuration, bundleID: bundleID)
        let store = MidgarStore(
            configuration: storeConfiguration(),
            identity: identity,
            http: MidgarHTTPClient(configuration: identity.authorizing(configuration))
        )
        Task {
            do {
                _ = try await identity.midgarId
                MidgarLog.info("Midgar ID ready", category: .store)
            } catch {
                MidgarLog.notice("Midgar ID not available yet: \(error)", category: .store)
            }
            await store.reportPurchaseHistory()
        }
        return MidgarProAccess(store: store)
    }

    /// The registry's `[commerce]` table for Crucible: both products grant `pro`.
    package static func storeConfiguration(directory: URL? = nil) -> MidgarStoreConfiguration {
        MidgarStoreConfiguration(
            appID: appID,
            productIDs: productIDs,
            entitlementsByProduct: Dictionary(uniqueKeysWithValues: productIDs.map { ($0, entitlement) }),
            mode: .purchases,
            directory: directory
        )
    }

    package func cachedStatus() async -> ProStatus {
        await status()
    }

    package func refreshStatus() async -> ProStatus? {
        await store.refresh()
        return await status()
    }

    package func statusUpdates() -> AsyncStream<ProStatus> {
        let store = store
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                for await event in await store.events() {
                    switch event {
                    case .entitlementsChanged, .purchaseApproved:
                        guard let self else { break }
                        continuation.yield(await self.status())
                    case .refused(let productID):
                        MidgarLog.error("Store refused an unverified transaction for \(productID)", category: .store)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    package func loadOffers() async throws -> [ProOffer] {
        let products: [Product]
        do {
            products = try await Product.products(for: Self.productIDs)
        } catch {
            MidgarLog.notice("Pro products failed to load: \(error.localizedDescription)", category: .store)
            throw ProOffersError.storeUnavailable
        }
        var offers: [ProOffer] = []
        for product in products {
            switch product.id {
            case Self.lifetimeID:
                offers.append(ProOffer(id: product.id, kind: .lifetime, priceText: product.displayPrice))
            case Self.yearlyID:
                offers.append(ProOffer(
                    id: product.id,
                    kind: .annual,
                    priceText: product.displayPrice,
                    monthlyEquivalentText: Self.monthlyEquivalent(of: product).map { "\($0) a month" },
                    trial: await Self.trial(for: product)
                ))
            default:
                continue
            }
        }
        guard !offers.isEmpty else { throw ProOffersError.noOffers }
        return offers.sorted { $0.kind == .lifetime && $1.kind != .lifetime }
    }

    package func purchase(offerID: String) async -> ProPurchaseOutcome {
        if await store.isEntitled(to: Self.entitlement) { return .alreadyOwned }
        do {
            switch try await store.purchase(offerID) {
            case .purchased:
                MidgarLog.info("Purchased \(offerID)", category: .store)
                return .purchased
            case .pending:
                return .pending
            case .cancelled:
                return .cancelled
            @unknown default:
                return .cancelled
            }
        } catch {
            MidgarLog.notice("Purchase of \(offerID) failed: \(error)", category: .store)
            return .failed(Self.failure(for: error))
        }
    }

    package func restore() async -> ProRestoreOutcome {
        do {
            try await store.restore()
        } catch {
            MidgarLog.notice("Restore failed: \(error)", category: .store)
            return .failed(Self.failure(for: error))
        }
        return await status().isPro ? .restored : .nothingToRestore
    }

    package func managementURL() async -> URL? {
        guard case .pro(let entitlement) = await status(), entitlement.kind == .subscription else { return nil }
        return URL(string: "https://apps.apple.com/account/subscriptions")
    }

    /// The Pro entitlement the store holds now, with the renewal state StoreKit reports for a subscription.
    private func status() async -> ProStatus {
        guard let entitlement = await store.entitlements.first(where: { $0.name == Self.entitlement }) else { return .free }
        let renewal = entitlement.kind == .subscription ? await Self.renewal(of: entitlement.productID) : nil
        return ProStatus(snapshot: ProEntitlementSnapshot(
            isActive: true,
            productIdentifier: entitlement.productID,
            expirationDate: entitlement.kind == .subscription ? (entitlement.expirationDate ?? .distantFuture) : nil,
            willRenew: renewal?.willRenew ?? false,
            isTrial: renewal?.isTrial ?? false,
            isFamilyShared: entitlement.ownership == .familyShared,
            billingIssueDetectedAt: renewal?.billingIssue == true ? Date() : nil
        ))
    }

    private struct Renewal {
        var willRenew: Bool
        var isTrial: Bool
        var billingIssue: Bool
    }

    /// Whether the subscription renews, is still in its free trial or is in billing retry, from StoreKit's
    /// status for the product's group; nil when StoreKit has no status for it.
    private static func renewal(of productID: String) async -> Renewal? {
        guard let product = try? await Product.products(for: [productID]).first,
              let statuses = try? await product.subscription?.status
        else { return nil }
        for status in statuses {
            guard case .verified(let transaction) = status.transaction, transaction.productID == productID,
                  case .verified(let info) = status.renewalInfo
            else { continue }
            return Renewal(
                willRenew: info.willAutoRenew,
                isTrial: isFreeTrial(transaction),
                billingIssue: status.state == .inBillingRetryPeriod || status.state == .inGracePeriod
            )
        }
        return nil
    }

    /// Whether the transaction is a free-trial period. Before iOS 17.2 StoreKit only says it is an introductory
    /// offer, which for Crucible has only ever been the free trial.
    private static func isFreeTrial(_ transaction: Transaction) -> Bool {
        if #available(iOS 17.2, tvOS 17.2, macOS 14.2, *) {
            return transaction.offer?.paymentMode == .freeTrial
        }
        return transaction.offerType == .introductory
    }

    /// The free trial this person can still have on the yearly plan, in days; nil when there is none or it was used.
    private static func trial(for product: Product) async -> ProOffer.Trial? {
        guard let subscription = product.subscription,
              let intro = subscription.introductoryOffer, intro.paymentMode == .freeTrial,
              await subscription.isEligibleForIntroOffer
        else { return nil }
        let period = intro.period
        switch period.unit {
        case .day: return .init(days: period.value)
        case .week: return .init(days: period.value * 7)
        case .month: return .init(days: period.value * 30)
        case .year: return .init(days: period.value * 365)
        @unknown default: return nil
        }
    }

    private static func monthlyEquivalent(of product: Product) -> String? {
        guard product.subscription?.subscriptionPeriod.unit == .year else { return nil }
        let monthly = product.price / 12
        return monthly.formatted(product.priceFormatStyle)
    }

    private static func failure(for error: Error) -> ProStoreFailure {
        let detail = String(describing: error)
        if let urlError = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(urlError.code) {
            return ProStoreFailure(.offline, detail: detail)
        }
        switch error as? MidgarStoreError {
        case .unknownProduct, .readOnly, .unsupportedPlatform:
            return ProStoreFailure(.storeUnavailable, detail: detail)
        case .storeKit(let message) where message.localizedCaseInsensitiveContains("not allowed"):
            return ProStoreFailure(.notAllowed, detail: detail)
        default:
            return ProStoreFailure(.unknown, detail: detail)
        }
    }
}
