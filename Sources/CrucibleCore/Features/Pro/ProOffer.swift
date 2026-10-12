import Foundation

/// One way to buy Pro, already priced and described for the user's storefront.
package struct ProOffer: Equatable, Sendable, Identifiable {
    package enum Kind: Equatable, Sendable {
        case lifetime
        case annual
    }

    package struct Trial: Equatable, Sendable {
        package var days: Int

        package init(days: Int) {
            self.days = days
        }
    }

    package var id: String
    package var kind: Kind
    package var priceText: String
    package var monthlyEquivalentText: String?
    package var trial: Trial?

    package init(id: String, kind: Kind, priceText: String, monthlyEquivalentText: String? = nil, trial: Trial? = nil) {
        self.id = id
        self.kind = kind
        self.priceText = priceText
        self.monthlyEquivalentText = monthlyEquivalentText
        self.trial = trial
    }

    package var title: String {
        switch kind {
        case .lifetime: return "Lifetime"
        case .annual: return "Annual"
        }
    }

    /// "Pay once · every update" or "Renews every year".
    package var detail: String {
        switch kind {
        case .lifetime: return "Pay once. Every update, on every device."
        case .annual: return "Renews every year. Cancel any time."
        }
    }

    /// The price line, including the trial when this user can still have it.
    package var priceLine: String {
        switch kind {
        case .lifetime: return priceText
        case .annual:
            guard let trial else { return "\(priceText) per year" }
            return "\(trial.days)-day free trial, then \(priceText) per year"
        }
    }

    /// The text of the button that buys this offer.
    package var buttonTitle: String {
        switch kind {
        case .lifetime: return "Unlock for \(priceText)"
        case .annual: return trial == nil ? "Subscribe for \(priceText) a year" : "Start \(trial?.days ?? 0)-day free trial"
        }
    }

    /// The auto-renewal terms Apple requires next to a subscription's price.
    package var renewalDisclosure: String? {
        guard kind == .annual else { return nil }
        let charge = trial.map { "Your \($0.days)-day free trial starts today. After it ends, your Apple Account is charged \(priceText) per year." }
            ?? "Your Apple Account is charged \(priceText) per year."
        return "\(charge) The subscription renews automatically unless you cancel at least 24 hours before the end of the current period. Manage or cancel it any time in your Apple Account settings."
    }
}
