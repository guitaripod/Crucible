import Foundation
import Testing
@testable import CrucibleCore

struct ProOfferTests {
    private let lifetime = ProOffer(id: "life", kind: .lifetime, priceText: "$24.99")
    private let annual = ProOffer(id: "year", kind: .annual, priceText: "$7.99")
    private let annualTrial = ProOffer(id: "year", kind: .annual, priceText: "$7.99", trial: .init(days: 14))

    @Test func theLifetimeOfferStatesAOneTimePrice() {
        #expect(lifetime.priceLine == "$24.99")
        #expect(lifetime.buttonTitle == "Unlock for $24.99")
        #expect(lifetime.renewalDisclosure == nil)
    }

    @Test func theAnnualOfferNamesTheTrialAndWhatItCostsAfterwards() {
        #expect(annualTrial.priceLine == "14-day free trial, then $7.99 per year")
        #expect(annualTrial.buttonTitle == "Start 14-day free trial")
        let disclosure = annualTrial.renewalDisclosure ?? ""
        #expect(disclosure.contains("14-day free trial starts today"))
        #expect(disclosure.contains("$7.99 per year"))
        #expect(disclosure.contains("cancel at least 24 hours before"))
    }

    @Test func theAnnualOfferWithoutATrialStatesThePriceAndTheRenewal() {
        #expect(annual.priceLine == "$7.99 per year")
        #expect(annual.buttonTitle == "Subscribe for $7.99 a year")
        #expect(annual.renewalDisclosure?.hasPrefix("Your Apple Account is charged $7.99 per year.") == true)
    }

    @Test func entitlementsDescribeThemselvesForTheProScreen() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = now.addingTimeInterval(86_400 * 30)
        #expect(ProEntitlement.included.summary() == "Included in this build")
        #expect(ProEntitlement(kind: .lifetime, productIdentifier: "life").summary() == "Lifetime")
        #expect(ProEntitlement(kind: .lifetime, productIdentifier: "life", isFamilyShared: true).summary() == "Lifetime, shared by your family")
        let renewing = ProEntitlement(kind: .subscription, productIdentifier: "year", expiresAt: later, willRenew: true).summary(now: now)
        #expect(renewing.hasPrefix("Annual · renews "))
        let trial = ProEntitlement(kind: .subscription, productIdentifier: "year", expiresAt: later, willRenew: true, isTrial: true).summary(now: now)
        #expect(trial.hasPrefix("Free trial · renews "))
        let ending = ProEntitlement(kind: .subscription, productIdentifier: "year", expiresAt: later, willRenew: false).summary(now: now)
        #expect(ending.hasPrefix("Annual · ends "))
        let trouble = ProEntitlement(kind: .subscription, productIdentifier: "year", expiresAt: later, willRenew: true, hasBillingIssue: true).summary(now: now)
        #expect(trouble.contains("payment problem"))
    }

    @Test func unknownStatusReadsAsLocked() {
        #expect(!ProStatus.unknown.isPro)
        #expect(!ProStatus.free.isPro)
        #expect(ProStatus.pro(.included).isPro)
    }
}

struct ProStatusSnapshotTests {
    private func snapshot(
        active: Bool = true,
        expires: Date? = nil,
        renews: Bool = false,
        trial: Bool = false,
        family: Bool = false,
        billing: Date? = nil
    ) -> ProEntitlementSnapshot {
        ProEntitlementSnapshot(isActive: active, productIdentifier: "product", expirationDate: expires, willRenew: renews, isTrial: trial, isFamilyShared: family, billingIssueDetectedAt: billing)
    }

    @Test func noEntitlementIsFree() {
        #expect(ProStatus(snapshot: nil) == .free)
        #expect(ProStatus(snapshot: snapshot(active: false)) == .free)
    }

    @Test func anActiveEntitlementWithoutAnExpiryIsTheLifetimeUnlock() {
        #expect(ProStatus(snapshot: snapshot()).entitlement?.kind == .lifetime)
    }

    @Test func anActiveEntitlementWithAnExpiryIsASubscription() {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let entitlement = ProStatus(snapshot: snapshot(expires: date, renews: true, trial: true)).entitlement
        #expect(entitlement?.kind == .subscription)
        #expect(entitlement?.expiresAt == date)
        #expect(entitlement?.willRenew == true)
        #expect(entitlement?.isTrial == true)
    }

    @Test func familySharingAndBillingProblemsCarryThrough() {
        let entitlement = ProStatus(snapshot: snapshot(expires: Date(), family: true, billing: Date())).entitlement
        #expect(entitlement?.isFamilyShared == true)
        #expect(entitlement?.hasBillingIssue == true)
    }
}
