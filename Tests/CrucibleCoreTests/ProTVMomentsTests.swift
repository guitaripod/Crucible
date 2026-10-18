import Foundation
import Testing
@testable import CrucibleCore

struct ProTVMomentsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func trial(endingIn seconds: TimeInterval, willRenew: Bool = true) -> ProStatus {
        .pro(ProEntitlement(
            kind: .subscription,
            productIdentifier: "yearly",
            expiresAt: now.addingTimeInterval(seconds),
            willRenew: willRenew,
            isTrial: true
        ))
    }

    private func isolatedLedger() -> ProMomentLedger {
        let name = "ProTVMomentsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ProMomentLedger(defaults: defaults)
    }

    @Test func firstFinishPitchesProToAFreeViewer() {
        let moment = ProTVMoments.firstFinish(status: .free, isStoreBacked: true, isDemo: false)
        #expect(moment?.action == .seePro)
    }

    @Test func firstFinishPointsATrialViewerAtStatistics() {
        let moment = ProTVMoments.firstFinish(status: trial(endingIn: 86_400 * 10), isStoreBacked: true, isDemo: false)
        #expect(moment?.action == .openStatistics)
    }

    @Test func firstFinishStaysQuietWhereProCannotBeSoldOrIsAlreadyPaid() {
        let lifetime = ProStatus.pro(ProEntitlement(kind: .lifetime, productIdentifier: "lifetime"))
        #expect(ProTVMoments.firstFinish(status: .unknown, isStoreBacked: true, isDemo: false) == nil)
        #expect(ProTVMoments.firstFinish(status: .free, isStoreBacked: false, isDemo: false) == nil)
        #expect(ProTVMoments.firstFinish(status: .free, isStoreBacked: true, isDemo: true) == nil)
        #expect(ProTVMoments.firstFinish(status: lifetime, isStoreBacked: true, isDemo: false) == nil)
    }

    @Test func trialNoticeComesOnlyInTheLastTwoDays() {
        #expect(ProTVMoments.trialEnding(status: trial(endingIn: 86_400 * 3), weekWatchSeconds: nil, now: now) == nil)
        #expect(ProTVMoments.trialEnding(status: trial(endingIn: 86_400 * 2), weekWatchSeconds: nil, now: now) != nil)
        #expect(ProTVMoments.trialEnding(status: trial(endingIn: 60), weekWatchSeconds: nil, now: now) != nil)
        #expect(ProTVMoments.trialEnding(status: trial(endingIn: -60), weekWatchSeconds: nil, now: now) == nil)
    }

    @Test func trialNoticeIgnoresPaidAndFreeStatuses() {
        let paid = ProStatus.pro(ProEntitlement(kind: .subscription, productIdentifier: "yearly", expiresAt: now.addingTimeInterval(3600), willRenew: true))
        #expect(ProTVMoments.trialEnding(status: paid, weekWatchSeconds: nil, now: now) == nil)
        #expect(ProTVMoments.trialEnding(status: .free, weekWatchSeconds: nil, now: now) == nil)
        #expect(ProTVMoments.trialEnding(status: .unknown, weekWatchSeconds: nil, now: now) == nil)
    }

    @Test func trialNoticeSaysWhatHappensNext() throws {
        let renewing = try #require(ProTVMoments.trialEnding(status: trial(endingIn: 3600), weekWatchSeconds: 7_800, now: now))
        #expect(renewing.message.contains("renews yearly"))
        #expect(renewing.message.contains("2h 10m"))
        #expect(renewing.message.contains(ProTVPresentation.manageSubscriptionText))

        let cancelled = try #require(ProTVMoments.trialEnding(status: trial(endingIn: 3600, willRenew: false), weekWatchSeconds: 0, now: now))
        #expect(cancelled.message.contains("will not renew"))
        #expect(!cancelled.message.contains("This week"))
        #expect(cancelled.message.contains("lock again"))
    }

    @Test func ledgerShowsFirstFinishOnce() {
        let ledger = isolatedLedger()
        #expect(!ledger.hasShown(.firstFinish))
        ledger.markShown(.firstFinish)
        #expect(ledger.hasShown(.firstFinish))
    }

    @Test func ledgerShowsTheTrialNoticeOncePerEndDate() {
        let ledger = isolatedLedger()
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let renewed = first.addingTimeInterval(365 * 86_400)
        ledger.markShown(.trialEnding(first))
        #expect(ledger.hasShown(.trialEnding(first)))
        #expect(!ledger.hasShown(.trialEnding(renewed)))
    }
}
