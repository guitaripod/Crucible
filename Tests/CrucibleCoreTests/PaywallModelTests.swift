import Foundation
import Testing
@testable import CrucibleCore

@MainActor
struct PaywallModelTests {
    private func model(
        _ store: ScriptedProAccess.StoreBehavior = .ok,
        restore: ScriptedProAccess.RestoreBehavior = .none,
        status: ProStatus = .free,
        trial: Bool = true
    ) -> (PaywallModel, ProAccess) {
        let access = ProAccess(provider: ScriptedProAccess(status: status, store: store, restore: restore, trialEligible: trial, delay: .milliseconds(1)))
        access.apply(status)
        return (PaywallModel(access: access, request: PaywallRequest(feature: .fullStatistics)), access)
    }

    private func settle(_ model: PaywallModel, until condition: @MainActor (PaywallModel.State) -> Bool) async {
        for _ in 0..<300 where !condition(model.state) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func loadingShowsBothOffersAndSelectsTheLifetimeOne() async {
        let (model, _) = model()
        #expect(model.state.phase == .loading)
        model.start()
        await settle(model) { !$0.offers.isEmpty }
        #expect(model.state.offers.map(\.kind) == [.lifetime, .annual])
        #expect(model.state.selectedOffer?.kind == .lifetime)
        #expect(model.state.offers.last?.trial?.days == 14)
    }

    @Test func aUserWhoAlreadyUsedTheTrialSeesNoTrial() async {
        let (model, _) = model(trial: false)
        model.start()
        await settle(model) { !$0.offers.isEmpty }
        #expect(model.state.offers.last?.trial == nil)
    }

    @Test func buyingTheSelectedOfferUnlocksProAndFinishes() async {
        let (model, access) = model()
        var finished: Bool?
        model.onFinish = { finished = $0 }
        model.start()
        await settle(model) { !$0.offers.isEmpty }
        model.purchaseSelected()
        #expect(model.state.isBusy)
        await settle(model) { $0.unlocked }
        #expect(finished == true)
        #expect(access.isPro)
        #expect(access.status.entitlement?.kind == .lifetime)
    }

    @Test func choosingTheAnnualOfferStartsASubscription() async {
        let (model, access) = model()
        model.start()
        await settle(model) { !$0.offers.isEmpty }
        model.select(ScriptedProAccess.annualID)
        model.purchaseSelected()
        await settle(model) { $0.unlocked }
        #expect(access.status.entitlement?.kind == .subscription)
        #expect(access.status.entitlement?.isTrial == true)
    }

    @Test func cancellingThePurchaseSheetLeavesThePaywallOpenAndQuiet() async {
        let (model, access) = model(.cancel)
        var finished: Bool?
        model.onFinish = { finished = $0 }
        model.start()
        await settle(model) { !$0.offers.isEmpty }
        model.purchaseSelected()
        await settle(model) { $0.busy == .idle }
        #expect(model.state.notice == nil)
        #expect(finished == nil)
        #expect(!access.isPro)
    }

    @Test func aPurchaseWaitingForApprovalSaysSoAndStaysLocked() async {
        let (model, access) = model(.pending)
        model.start()
        await settle(model) { !$0.offers.isEmpty }
        model.purchaseSelected()
        await settle(model) { $0.notice != nil }
        #expect(model.state.notice == .pending)
        #expect(PaywallModel.message(for: .pending).contains("waiting for approval"))
        #expect(!access.isPro)
    }

    @Test func aStoreThatCannotLoadTheOffersShowsThemAsUnavailable() async {
        let (model, _) = model(.fail)
        model.start()
        await settle(model) { $0.phase != .loading }
        #expect({
            if case .unavailable = model.state.phase { return true }
            return false
        }())
    }

    @Test func aStoreThatFailsDuringThePurchaseShowsAFailureNotice() async {
        let access = ProAccess(provider: PurchaseFailingStore())
        access.apply(.free)
        let model = PaywallModel(access: access)
        model.start()
        await settle(model) { !$0.offers.isEmpty }
        model.purchaseSelected()
        await settle(model) { $0.notice != nil }
        guard case .failure(let text) = model.state.notice else {
            Issue.record("expected a failure notice")
            return
        }
        #expect(text.contains("You have not been charged"))
        #expect(!model.state.isBusy)
    }

    @Test func goingOfflineOnTheOffersOffersARetry() async {
        let (model, _) = model(.offline)
        model.start()
        await settle(model) { $0.phase != .loading }
        #expect(model.state.phase == .unavailable(PaywallModel.message(for: .offline)))
    }

    @Test func aRegionWithNoOffersSaysSo() async {
        let (model, _) = model(.empty)
        model.start()
        await settle(model) { $0.phase != .loading }
        #expect(model.state.phase == .unavailable(PaywallModel.message(for: .noOffers)))
    }

    @Test func restoringAnEarlierPurchaseUnlocksProAndFinishes() async {
        let (model, access) = model(restore: .found)
        var finished: Bool?
        model.onFinish = { finished = $0 }
        model.start()
        await settle(model) { !$0.offers.isEmpty }
        model.restore()
        #expect(model.state.busy == .restoring)
        await settle(model) { $0.unlocked }
        #expect(finished == true)
        #expect(access.isPro)
    }

    @Test func restoringWithNothingToRestoreSaysSo() async {
        let (model, access) = model(restore: .none)
        model.start()
        await settle(model) { !$0.offers.isEmpty }
        model.restore()
        await settle(model) { $0.notice != nil }
        #expect(model.state.notice == .nothingToRestore)
        #expect(!access.isPro)
        #expect(!model.state.unlocked)
    }

    @Test func aFailedRestoreShowsAFailureNotice() async {
        let (model, _) = model(restore: .fail)
        model.start()
        await settle(model) { !$0.offers.isEmpty }
        model.restore()
        await settle(model) { $0.notice != nil }
        if case .failure = model.state.notice {} else { Issue.record("expected a failure notice") }
    }

    @Test func aSecondTapWhileBusyIsIgnored() async {
        let (model, _) = model()
        model.start()
        await settle(model) { !$0.offers.isEmpty }
        model.purchaseSelected()
        let busy = model.state.busy
        model.purchaseSelected()
        model.restore()
        model.select(ScriptedProAccess.annualID)
        #expect(model.state.busy == busy)
        #expect(model.state.selectedOffer?.kind == .lifetime)
        await settle(model) { $0.unlocked }
    }

    @Test func proAlreadyOnClosesThePaywallAtOnce() {
        let (model, _) = model(status: .pro(.included))
        var finished: Bool?
        model.onFinish = { finished = $0 }
        model.start()
        #expect(finished == true)
    }

    @Test func closingThePaywallReportsWhetherProIsOn() {
        let (model, _) = model()
        var finished: Bool?
        model.onFinish = { finished = $0 }
        model.cancel()
        #expect(finished == false)
    }

    @Test func retryingAfterAFailureLoadsTheOffers() async {
        let (model, _) = model(.empty)
        model.start()
        await settle(model) { $0.phase != .loading }
        model.retry()
        #expect(model.state.phase == .loading)
    }
}

private actor PurchaseFailingStore: ProAccessProviding {
    nonisolated let isStoreBacked = true

    func cachedStatus() async -> ProStatus { .free }
    func refreshStatus() async -> ProStatus? { .free }
    nonisolated func statusUpdates() -> AsyncStream<ProStatus> { AsyncStream { $0.finish() } }
    func loadOffers() async throws -> [ProOffer] { [ProOffer(id: "life", kind: .lifetime, priceText: "$24.99")] }
    func purchase(offerID: String) async -> ProPurchaseOutcome { .failed(ProStoreFailure(.unknown)) }
    func restore() async -> ProRestoreOutcome { .nothingToRestore }
    func managementURL() async -> URL? { nil }
}
