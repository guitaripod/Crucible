import Foundation
import Testing
@testable import CrucibleCore

struct ProTVPresentationTests {
    private let lifetime = ProStatus.pro(ProEntitlement(kind: .lifetime, productIdentifier: "life"))
    private let renewing = ProStatus.pro(ProEntitlement(kind: .subscription, productIdentifier: "year", expiresAt: Date(timeIntervalSince1970: 1_800_000_000), willRenew: true))

    @Test func onlyFreeStoreBackedInstallsSeeLocks() {
        #expect(ProTVPresentation.showsLocks(status: .free, isStoreBacked: true))
        #expect(ProTVPresentation.showsLocks(status: .unknown, isStoreBacked: true))
        #expect(!ProTVPresentation.showsLocks(status: lifetime, isStoreBacked: true))
        #expect(!ProTVPresentation.showsLocks(status: .pro(.included), isStoreBacked: false))
        #expect(!ProTVPresentation.showsLocks(status: .free, isStoreBacked: false))
    }

    @Test func theRowPitchesForFreeUsersAndShowsThePlanForProUsers() {
        #expect(ProTVPresentation.rowSubtitle(for: .free) == "Unlock full Statistics and Top Shelf")
        #expect(ProTVPresentation.rowSubtitle(for: .unknown) == "Unlock full Statistics and Top Shelf")
        #expect(ProTVPresentation.rowSubtitle(for: lifetime) == "Lifetime")
        let renewal = ProTVPresentation.rowSubtitle(for: renewing)
        #expect(renewal.hasPrefix("Annual \u{00B7} renews "))
    }

    @Test func theReasonNamesTheFeatureTheUserReachedFor() {
        #expect(ProTVPresentation.reasonLine(for: nil) == nil)
        #expect(ProTVPresentation.reasonLine(for: .fullStatistics)?.contains("Month, Year, All") == true)
        #expect(ProTVPresentation.reasonLine(for: .topShelf) == "Top Shelf is part of Crucible Pro.")
    }

    @Test func theLegalTextSpellsOutBothPagesBecauseTvOSHasNoLinks() {
        let text = ProTVPresentation.legalText
        #expect(text.contains("Terms of Use\nhttps://www.apple.com/legal/internet-services/itunes/dev/stdeula/"))
        #expect(text.contains("Privacy Policy\nhttps://midgarcorp.cc/crucible/privacy/"))
    }

    @Test func theDisplayedLegalTextWrapsAtSlashesAndKeepsEveryAddressIntact() {
        let display = ProTVPresentation.legalDisplayText
        #expect(display.contains("https://www.apple.com/\u{200B}legal/\u{200B}internet-services/\u{200B}itunes/\u{200B}dev/\u{200B}stdeula/\u{200B}"))
        #expect(display.replacingOccurrences(of: "\u{200B}", with: "") == ProTVPresentation.legalText)
    }

    @Test func theManageTextPointsAtTheAppleTVSettingsPath() {
        #expect(ProTVPresentation.manageSubscriptionText == "To manage or cancel: Settings > Users & Accounts > your account > Subscriptions")
    }

    @MainActor
    @Test func aRestoreEndsInAnAlertThatMatchesWhatHappened() {
        #expect(ProTVPresentation.restoreAlert(for: .restored, isPro: true).title == "Crucible Pro Restored")
        #expect(ProTVPresentation.restoreAlert(for: .restored, isPro: false).title == "Nothing to Restore")
        #expect(ProTVPresentation.restoreAlert(for: .nothingToRestore, isPro: false).message == PaywallModel.message(for: .nothingToRestore))
        let failed = ProTVPresentation.restoreAlert(for: .failed(ProStoreFailure(.offline)), isPro: false)
        #expect(failed.title == "Couldn\u{2019}t Restore")
        #expect(failed.message == PaywallModel.message(for: ProStoreFailure(.offline)))
    }
}
