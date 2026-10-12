import Foundation

/// A store that does what the environment tells it to, for UI tests and the debug builds: every purchase and restore
/// path can be driven without a sandbox account.
///
/// - `CRUCIBLE_PRO`: `free` (default), `lifetime`, `annual` or `trial`, the status the app starts with.
/// - `CRUCIBLE_PRO_STORE`: `ok` (default), `cancel`, `pending`, `fail`, `offline` or `empty`, how the store answers.
/// - `CRUCIBLE_PRO_RESTORE`: `found`, `none` (default) or `fail`.
/// - `CRUCIBLE_PRO_TRIAL`: `0` hides the free trial from the annual offer.
/// - `CRUCIBLE_PRO_DELAY_MS`: how long every store call takes, 400 by default.
package actor ScriptedProAccess: ProAccessProviding {
    package enum StoreBehavior: String, Sendable {
        case ok, cancel, pending, fail, offline, empty
    }

    package enum RestoreBehavior: String, Sendable {
        case found, none, fail
    }

    package static let lifetimeID = "com.guitaripod.crucible.pro.lifetime"
    package static let annualID = "com.guitaripod.crucible.pro.yearly"

    package nonisolated let isStoreBacked = true

    private var status: ProStatus
    private let store: StoreBehavior
    private let restoreBehavior: RestoreBehavior
    private let trialEligible: Bool
    private let delay: Duration
    private var continuations: [UUID: AsyncStream<ProStatus>.Continuation] = [:]

    package init(
        status: ProStatus = .free,
        store: StoreBehavior = .ok,
        restore: RestoreBehavior = .none,
        trialEligible: Bool = true,
        delay: Duration = .milliseconds(400)
    ) {
        self.status = status
        self.store = store
        self.restoreBehavior = restore
        self.trialEligible = trialEligible
        self.delay = delay
    }

    package static func fromEnvironment(_ environment: [String: String]) -> ScriptedProAccess? {
        guard let start = environment["CRUCIBLE_PRO"] else { return nil }
        let status: ProStatus
        switch start {
        case "lifetime": status = .pro(ProEntitlement(kind: .lifetime, productIdentifier: lifetimeID))
        case "annual": status = .pro(ProEntitlement(kind: .subscription, productIdentifier: annualID, expiresAt: Date().addingTimeInterval(86_400 * 300), willRenew: true))
        case "trial": status = .pro(ProEntitlement(kind: .subscription, productIdentifier: annualID, expiresAt: Date().addingTimeInterval(86_400 * 12), willRenew: true, isTrial: true))
        default: status = .free
        }
        return ScriptedProAccess(
            status: status,
            store: environment["CRUCIBLE_PRO_STORE"].flatMap(StoreBehavior.init(rawValue:)) ?? .ok,
            restore: environment["CRUCIBLE_PRO_RESTORE"].flatMap(RestoreBehavior.init(rawValue:)) ?? .none,
            trialEligible: environment["CRUCIBLE_PRO_TRIAL"] != "0",
            delay: .milliseconds(environment["CRUCIBLE_PRO_DELAY_MS"].flatMap(Int.init) ?? 400)
        )
    }

    package func cachedStatus() async -> ProStatus { status }

    package func refreshStatus() async -> ProStatus? {
        try? await Task.sleep(for: delay)
        return store == .offline ? nil : status
    }

    package nonisolated func statusUpdates() -> AsyncStream<ProStatus> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(continuation, id: id) }
            continuation.onTermination = { _ in Task { await self.unregister(id) } }
        }
    }

    package func loadOffers() async throws -> [ProOffer] {
        try? await Task.sleep(for: delay)
        switch store {
        case .offline: throw ProOffersError.offline
        case .empty: throw ProOffersError.noOffers
        case .fail: throw ProOffersError.storeUnavailable
        case .ok, .cancel, .pending: break
        }
        return [
            ProOffer(id: Self.lifetimeID, kind: .lifetime, priceText: "$24.99"),
            ProOffer(id: Self.annualID, kind: .annual, priceText: "$7.99", monthlyEquivalentText: "$0.67 a month", trial: trialEligible ? .init(days: 14) : nil),
        ]
    }

    package func purchase(offerID: String) async -> ProPurchaseOutcome {
        try? await Task.sleep(for: delay)
        switch store {
        case .cancel: return .cancelled
        case .pending: return .pending
        case .fail: return .failed(ProStoreFailure(.unknown))
        case .offline: return .failed(ProStoreFailure(.offline))
        case .empty, .ok:
            if offerID == Self.lifetimeID {
                update(.pro(ProEntitlement(kind: .lifetime, productIdentifier: offerID)))
            } else {
                update(.pro(ProEntitlement(kind: .subscription, productIdentifier: offerID, expiresAt: Date().addingTimeInterval(86_400 * (trialEligible ? 14 : 365)), willRenew: true, isTrial: trialEligible)))
            }
            return .purchased
        }
    }

    package func restore() async -> ProRestoreOutcome {
        try? await Task.sleep(for: delay)
        switch restoreBehavior {
        case .found:
            update(.pro(ProEntitlement(kind: .lifetime, productIdentifier: Self.lifetimeID)))
            return .restored
        case .none: return .nothingToRestore
        case .fail: return .failed(ProStoreFailure(.storeUnavailable))
        }
    }

    package func managementURL() async -> URL? {
        URL(string: "https://apps.apple.com/account/subscriptions")
    }

    private func update(_ new: ProStatus) {
        status = new
        for continuation in continuations.values { continuation.yield(new) }
    }

    private func register(_ continuation: AsyncStream<ProStatus>.Continuation, id: UUID) {
        continuations[id] = continuation
    }

    private func unregister(_ id: UUID) {
        continuations[id] = nil
    }
}
