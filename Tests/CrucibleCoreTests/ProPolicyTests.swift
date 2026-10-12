import Foundation
import Testing
@testable import CrucibleCore

struct ProPolicyTests {
    @Test func aFreeInstallDownloadsOneTitleAtATime() {
        #expect(ProPolicy.downloadDecision(isPro: false, activeDownloads: 0) == .allow)
        #expect(ProPolicy.downloadDecision(isPro: false, activeDownloads: 1) == .requiresPro)
        #expect(ProPolicy.downloadDecision(isPro: false, activeDownloads: 3) == .requiresPro)
    }

    @Test func aFreeInstallNeverDownloadsABatch() {
        #expect(ProPolicy.downloadDecision(isPro: false, activeDownloads: 0, adding: 2) == .requiresPro)
        #expect(ProPolicy.downloadDecision(isPro: false, activeDownloads: 0, adding: 10) == .requiresPro)
    }

    @Test func proDownloadsWithoutALimit() {
        #expect(ProPolicy.downloadDecision(isPro: true, activeDownloads: 12, adding: 24) == .allow)
    }

    @Test func keepingTheNextEpisodesIsPro() {
        #expect(!ProPolicy.allowsKeepNextEpisodes(isPro: false))
        #expect(ProPolicy.allowsKeepNextEpisodes(isPro: true))
    }

    @Test func eachPlatformListsOnlyTheFeaturesItHas() {
        let phone = ProFeature.listed(isTV: false)
        let tv = ProFeature.listed(isTV: true)
        #expect(phone.contains(.unlimitedDownloads) && !phone.contains(.topShelf))
        #expect(tv.contains(.topShelf) && !tv.contains(.unlimitedDownloads))
        #expect(phone.contains(.fullStatistics) && tv.contains(.fullStatistics))
        #expect(phone.contains(.yearInReviewPoster) && tv.contains(.yearInReviewPoster))
    }
}
