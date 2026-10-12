import Foundation
import Testing
@testable import CrucibleCore

@MainActor
struct ProAccessTests {
    private func settle(_ access: ProAccess, until condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func scripted(_ status: ProStatus = .free, store: ScriptedProAccess.StoreBehavior = .ok, restore: ScriptedProAccess.RestoreBehavior = .none) -> ScriptedProAccess {
        ScriptedProAccess(status: status, store: store, restore: restore, delay: .milliseconds(1))
    }

    @Test func sourceBuildsAreUnlockedAndStoreFree() {
        let access = ProAccess(provider: UnlockedProAccess())
        #expect(access.isPro)
        #expect(!access.isStoreBacked)
        #expect(access.status == .pro(.included))
    }

    @Test func aStoreBackedInstallStartsLockedUntilTheStoreAnswers() {
        let access = ProAccess(provider: scripted())
        #expect(access.status == .unknown)
        #expect(!access.isPro)
        #expect(!access.allows(.fullStatistics))
    }

    @Test func startingReadsTheCachedStatusAndThenTheFreshOne() async {
        let access = ProAccess(provider: scripted(.pro(ProEntitlement(kind: .lifetime, productIdentifier: "life"))))
        access.start()
        await settle(access) { access.isPro }
        #expect(access.isPro)
        #expect(access.allows(.unlimitedDownloads))
    }

    @Test func aFreeUserStaysFreeAndSeesNoFlash() async {
        let access = ProAccess(provider: scripted(.free))
        var seen: [ProStatus] = []
        access.observe { seen.append($0) }
        access.start()
        await settle(access) { access.status == .free }
        #expect(access.status == .free)
        #expect(!seen.contains { $0.isPro })
    }

    @Test func anUnreachableStoreKeepsTheCachedProStatus() async {
        let access = ProAccess(provider: scripted(.pro(ProEntitlement(kind: .lifetime, productIdentifier: "life")), store: .offline))
        access.start()
        await settle(access) { access.isPro }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(access.isPro)
    }

    @Test func observersHearAboutChangesUntilTheyStop() {
        let access = ProAccess(provider: scripted())
        var changes = 0
        let token = access.observe { _ in changes += 1 }
        access.apply(.free)
        access.apply(.free)
        #expect(changes == 1)
        access.stopObserving(token)
        access.apply(.pro(.included))
        #expect(changes == 1)
    }

    @Test func requestingAnUnlockWhenProIsOnCompletesWithoutAPaywall() {
        let access = ProAccess(provider: UnlockedProAccess())
        var shown = false
        access.paywallPresenter = { _, _ in shown = true }
        var result: Bool?
        access.requestUnlock(.fullStatistics) { result = $0 }
        #expect(result == true)
        #expect(!shown)
    }

    @Test func requestingAnUnlockShowsThePaywallAndReportsTheOutcome() {
        let access = ProAccess(provider: scripted())
        access.apply(.free)
        var requested: PaywallRequest?
        var finish: (@MainActor (Bool) -> Void)?
        access.paywallPresenter = { request, completion in
            requested = request
            finish = completion
        }
        var result: Bool?
        access.requestUnlock(.unlimitedDownloads) { result = $0 }
        #expect(requested?.feature == .unlimitedDownloads)
        #expect(result == nil)
        finish?(false)
        #expect(result == false)
    }

    @Test func requestingAnUnlockWithNoScreenToShowItFailsClosed() {
        let access = ProAccess(provider: scripted())
        access.apply(.free)
        var result: Bool?
        access.requestUnlock(.topShelf) { result = $0 }
        #expect(result == false)
    }

    @Test func installingAProviderResetsTheStatus() {
        let access = ProAccess(provider: UnlockedProAccess())
        #expect(access.isPro)
        access.install(scripted())
        #expect(access.status == .unknown)
        #expect(access.isStoreBacked)
    }

    @Test func theEnvironmentBuildsAScriptedStore() async {
        #expect(ScriptedProAccess.fromEnvironment([:]) == nil)
        let store = ScriptedProAccess.fromEnvironment(["CRUCIBLE_PRO": "trial", "CRUCIBLE_PRO_DELAY_MS": "1"])
        let status = await store?.cachedStatus()
        #expect(status?.entitlement?.isTrial == true)
        let free = ScriptedProAccess.fromEnvironment(["CRUCIBLE_PRO": "free", "CRUCIBLE_PRO_TRIAL": "0", "CRUCIBLE_PRO_DELAY_MS": "1"])
        let offers = try? await free?.loadOffers()
        #expect(offers?.first { $0.kind == .annual }?.trial == nil)
    }
}
