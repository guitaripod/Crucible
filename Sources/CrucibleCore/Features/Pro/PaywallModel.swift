import Foundation

/// What the paywall shows and does, with no UIKit in it: the iPhone sheet and the Apple TV screen both render this state
/// and call these methods, so every purchase path behaves the same on both.
@MainActor
package final class PaywallModel {
    package enum Phase: Equatable, Sendable {
        case loading
        case ready([ProOffer])
        case unavailable(String)
    }

    package enum Busy: Equatable, Sendable {
        case idle
        case purchasing(String)
        case restoring
    }

    package enum Notice: Equatable, Sendable {
        case pending
        case nothingToRestore
        case failure(String)
    }

    package struct State: Equatable, Sendable {
        package var phase: Phase = .loading
        package var busy: Busy = .idle
        package var selectedOfferID: String?
        package var notice: Notice?
        package var unlocked = false

        package var offers: [ProOffer] {
            if case .ready(let offers) = phase { return offers }
            return []
        }

        package var selectedOffer: ProOffer? {
            offers.first { $0.id == selectedOfferID }
        }

        package var isBusy: Bool { busy != .idle }
    }

    package let request: PaywallRequest
    package var onChange: ((State) -> Void)?
    package var onFinish: ((Bool) -> Void)?
    package private(set) var state = State() {
        didSet { if state != oldValue { onChange?(state) } }
    }

    private let access: ProAccess
    private var loadTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var finished = false

    package init(access: ProAccess = .shared, request: PaywallRequest = PaywallRequest()) {
        self.access = access
        self.request = request
    }

    deinit {
        loadTask?.cancel()
        actionTask?.cancel()
    }

    /// Loads the offers. Pro already being on closes the paywall at once.
    package func start() {
        guard !finished else { return }
        if access.isPro {
            finish(unlocked: true)
            return
        }
        state.phase = .loading
        state.notice = nil
        loadTask?.cancel()
        let provider = access.provider
        loadTask = Task { [weak self] in
            do {
                let offers = try await provider.loadOffers()
                self?.offersLoaded(offers)
            } catch let error as ProOffersError {
                self?.offersFailed(error)
            } catch {
                self?.offersFailed(.storeUnavailable)
            }
        }
    }

    package func retry() { start() }

    package func select(_ offerID: String) {
        guard !state.isBusy, state.offers.contains(where: { $0.id == offerID }) else { return }
        state.selectedOfferID = offerID
    }

    /// Buys the selected offer.
    package func purchaseSelected() {
        guard !state.isBusy, !finished, let offer = state.selectedOffer else { return }
        state.busy = .purchasing(offer.id)
        state.notice = nil
        let provider = access.provider
        actionTask = Task { [weak self] in
            let outcome = await provider.purchase(offerID: offer.id)
            await self?.purchaseFinished(outcome)
        }
    }

    package func restore() {
        guard !state.isBusy, !finished else { return }
        state.busy = .restoring
        state.notice = nil
        let provider = access.provider
        actionTask = Task { [weak self] in
            let outcome = await provider.restore()
            await self?.restoreFinished(outcome)
        }
    }

    /// The user closed the paywall without buying.
    package func cancel() {
        guard !finished else { return }
        finish(unlocked: access.isPro)
    }

    package func dismissNotice() {
        state.notice = nil
    }

    private func offersLoaded(_ offers: [ProOffer]) {
        guard !offers.isEmpty else {
            offersFailed(.noOffers)
            return
        }
        let preferred = offers.first { $0.kind == .lifetime } ?? offers[0]
        state.selectedOfferID = state.selectedOfferID.flatMap { id in offers.contains { $0.id == id } ? id : nil } ?? preferred.id
        state.phase = .ready(offers)
    }

    private func offersFailed(_ error: ProOffersError) {
        state.phase = .unavailable(Self.message(for: error))
    }

    private func purchaseFinished(_ outcome: ProPurchaseOutcome) async {
        switch outcome {
        case .purchased, .alreadyOwned:
            await access.refreshNow()
            state.busy = .idle
            if access.isPro {
                finish(unlocked: true)
            } else {
                state.notice = .failure("The purchase went through but Pro has not turned on yet. Try Restore Purchases in a moment.")
            }
        case .cancelled:
            state.busy = .idle
        case .pending:
            state.busy = .idle
            state.notice = .pending
        case .failed(let failure):
            state.busy = .idle
            state.notice = .failure(Self.message(for: failure))
        }
    }

    private func restoreFinished(_ outcome: ProRestoreOutcome) async {
        switch outcome {
        case .restored:
            await access.refreshNow()
            state.busy = .idle
            if access.isPro {
                finish(unlocked: true)
            } else {
                state.notice = .nothingToRestore
            }
        case .nothingToRestore:
            state.busy = .idle
            state.notice = .nothingToRestore
        case .failed(let failure):
            state.busy = .idle
            state.notice = .failure(Self.message(for: failure))
        }
    }

    private func finish(unlocked: Bool) {
        guard !finished else { return }
        finished = true
        state.unlocked = unlocked
        onFinish?(unlocked)
    }

    package static func message(for error: ProOffersError) -> String {
        switch error {
        case .offline: return "Crucible Pro could not be loaded because you appear to be offline. Check your connection and try again."
        case .storeUnavailable: return "The App Store did not answer. Try again in a moment."
        case .noOffers: return "Crucible Pro is not available in your region right now."
        }
    }

    package static func message(for failure: ProStoreFailure) -> String {
        switch failure.reason {
        case .offline: return "You appear to be offline. Check your connection and try again. You have not been charged."
        case .storeUnavailable: return "The App Store did not answer. Try again in a moment. You have not been charged unless the App Store says otherwise."
        case .notAllowed: return "Purchases are turned off on this device. You can change that in Screen Time or in your Apple Account settings."
        case .unknown: return "The purchase could not be completed. You have not been charged. Try again, or use Restore Purchases if you already own Pro."
        }
    }

    package static func message(for notice: Notice) -> String {
        switch notice {
        case .pending: return "Your purchase is waiting for approval. Crucible Pro turns on as soon as it is approved."
        case .nothingToRestore: return "No Crucible Pro purchase was found for this Apple Account."
        case .failure(let text): return text
        }
    }
}
