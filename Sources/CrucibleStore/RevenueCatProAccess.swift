import CrucibleCore
import Foundation
import RevenueCat

/// Crucible Pro sold through RevenueCat: the `pro` entitlement, the `default` offering with a lifetime and an annual
/// package, and the App Store behind them. Everything the screens need is mapped to the store-free types in CrucibleCore.
package final class RevenueCatProAccess: ProAccessProviding {
    package static let entitlementID = "pro"

    package let isStoreBacked = true

    package init() {}

    /// Configures the SDK once, before the first screen. The key is the app's public SDK key, never a secret key.
    package static func configure(apiKey: String) {
        guard !Purchases.isConfigured else { return }
        Purchases.logLevel = .warn
        Purchases.configure(
            with: Configuration.Builder(withAPIKey: apiKey)
                .with(storeKitVersion: .storeKit2)
                .with(diagnosticsEnabled: false)
                .build()
        )
        AppLogger.info("RevenueCat configured", .store)
    }

    package func cachedStatus() async -> ProStatus {
        guard Purchases.isConfigured,
              let info = try? await Purchases.shared.customerInfo(fetchPolicy: .fromCacheOnly)
        else { return .unknown }
        return Self.status(from: info)
    }

    package func refreshStatus() async -> ProStatus? {
        guard Purchases.isConfigured else { return nil }
        do {
            return Self.status(from: try await Purchases.shared.customerInfo(fetchPolicy: .fetchCurrent))
        } catch {
            AppLogger.notice("Pro status refresh failed: \(error.localizedDescription)", .store)
            return nil
        }
    }

    package func statusUpdates() -> AsyncStream<ProStatus> {
        guard Purchases.isConfigured else { return AsyncStream { $0.finish() } }
        let infos = Purchases.shared.customerInfoStream
        return AsyncStream { continuation in
            let task = Task {
                for await info in infos { continuation.yield(Self.status(from: info)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    package func loadOffers() async throws -> [ProOffer] {
        guard Purchases.isConfigured else { throw ProOffersError.storeUnavailable }
        let offerings: Offerings
        do {
            offerings = try await Purchases.shared.offerings()
        } catch {
            throw Self.offersError(for: error)
        }
        guard let packages = offerings.current?.availablePackages else { throw ProOffersError.noOffers }
        var offers: [ProOffer] = []
        for package in packages {
            guard let kind = Self.kind(of: package) else { continue }
            let trial = kind == .annual ? await Self.trial(for: package) : nil
            offers.append(ProOffer(
                id: package.storeProduct.productIdentifier,
                kind: kind,
                priceText: package.storeProduct.localizedPriceString,
                monthlyEquivalentText: kind == .annual ? package.storeProduct.localizedPricePerMonth.map { "\($0) a month" } : nil,
                trial: trial
            ))
        }
        guard !offers.isEmpty else { throw ProOffersError.noOffers }
        return offers.sorted { $0.kind == .lifetime && $1.kind != .lifetime }
    }

    package func purchase(offerID: String) async -> ProPurchaseOutcome {
        guard Purchases.isConfigured else { return .failed(ProStoreFailure(.storeUnavailable)) }
        do {
            let offerings = try await Purchases.shared.offerings()
            guard let package = offerings.current?.availablePackages.first(where: { $0.storeProduct.productIdentifier == offerID }) else {
                return .failed(ProStoreFailure(.storeUnavailable, detail: "offer not in the current offering"))
            }
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return .cancelled }
            AppLogger.info("Purchased \(offerID)", .store)
            return .purchased
        } catch {
            return Self.outcome(for: error)
        }
    }

    package func restore() async -> ProRestoreOutcome {
        guard Purchases.isConfigured else { return .failed(ProStoreFailure(.storeUnavailable)) }
        do {
            let info = try await Purchases.shared.restorePurchases()
            return Self.status(from: info).isPro ? .restored : .nothingToRestore
        } catch {
            AppLogger.notice("Restore failed: \(error.localizedDescription)", .store)
            return .failed(Self.failure(for: error))
        }
    }

    package func managementURL() async -> URL? {
        guard Purchases.isConfigured else { return nil }
        return try? await Purchases.shared.customerInfo(fetchPolicy: .fromCacheOnly).managementURL
    }

    static func status(from info: CustomerInfo) -> ProStatus {
        guard let entitlement = info.entitlements[entitlementID] else { return .free }
        return ProStatus(snapshot: ProEntitlementSnapshot(
            isActive: entitlement.isActive,
            productIdentifier: entitlement.productIdentifier,
            expirationDate: entitlement.expirationDate,
            willRenew: entitlement.willRenew,
            isTrial: entitlement.periodType == .trial,
            isFamilyShared: entitlement.ownershipType == .familyShared,
            billingIssueDetectedAt: entitlement.billingIssueDetectedAt
        ))
    }

    private static func kind(of package: Package) -> ProOffer.Kind? {
        switch package.packageType {
        case .lifetime: return .lifetime
        case .annual: return .annual
        default: return nil
        }
    }

    /// The free trial this user can still have on the package, in days, or nil when there is none or it was used.
    private static func trial(for package: Package) async -> ProOffer.Trial? {
        let product = package.storeProduct
        guard let intro = product.introductoryDiscount, intro.paymentMode == .freeTrial else { return nil }
        guard await Purchases.shared.checkTrialOrIntroDiscountEligibility(product: product) == .eligible else { return nil }
        let period = intro.subscriptionPeriod
        let days: Int
        switch period.unit {
        case .day: days = period.value
        case .week: days = period.value * 7
        case .month: days = period.value * 30
        case .year: days = period.value * 365
        @unknown default: return nil
        }
        return .init(days: days)
    }

    private static func outcome(for error: Error) -> ProPurchaseOutcome {
        switch error as? ErrorCode {
        case .purchaseCancelledError: return .cancelled
        case .paymentPendingError: return .pending
        case .productAlreadyPurchasedError: return .alreadyOwned
        default: return .failed(failure(for: error))
        }
    }

    private static func failure(for error: Error) -> ProStoreFailure {
        let detail = error.localizedDescription
        switch error as? ErrorCode {
        case .networkError, .offlineConnectionError: return ProStoreFailure(.offline, detail: detail)
        case .purchaseNotAllowedError: return ProStoreFailure(.notAllowed, detail: detail)
        case .storeProblemError, .productNotAvailableForPurchaseError, .productRequestTimedOut: return ProStoreFailure(.storeUnavailable, detail: detail)
        default: return ProStoreFailure(.unknown, detail: detail)
        }
    }

    private static func offersError(for error: Error) -> ProOffersError {
        switch error as? ErrorCode {
        case .networkError, .offlineConnectionError: return .offline
        default: return .storeUnavailable
        }
    }
}
