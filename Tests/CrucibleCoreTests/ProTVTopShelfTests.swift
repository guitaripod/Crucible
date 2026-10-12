import Foundation
import Testing
@testable import CrucibleCore

struct ProTVTopShelfTests {
    @Test func proInstallsPublish() {
        #expect(ProTVTopShelf.action(for: .pro(.included)) == .publish)
        #expect(ProTVTopShelf.action(for: .pro(ProEntitlement(kind: .lifetime, productIdentifier: "life"))) == .publish)
        #expect(ProTVTopShelf.action(for: .pro(ProEntitlement(kind: .subscription, productIdentifier: "year", isTrial: true))) == .publish)
    }

    @Test func freeInstallsClearWhatAnEarlierVersionOrAnExpiredPlanLeft() {
        #expect(ProTVTopShelf.action(for: .free) == .clear)
    }

    @Test func anUnansweredStoreLeavesTheTopShelfAlone() {
        #expect(ProTVTopShelf.action(for: .unknown) == .wait)
    }
}
