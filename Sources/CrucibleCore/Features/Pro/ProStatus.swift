import Foundation

/// How a Pro unlock was obtained and what is left of it.
package struct ProEntitlement: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        case lifetime
        case subscription
        case included
    }

    package var kind: Kind
    package var productIdentifier: String
    package var expiresAt: Date?
    package var willRenew: Bool
    package var isTrial: Bool
    package var isFamilyShared: Bool
    package var hasBillingIssue: Bool

    package init(
        kind: Kind,
        productIdentifier: String,
        expiresAt: Date? = nil,
        willRenew: Bool = false,
        isTrial: Bool = false,
        isFamilyShared: Bool = false,
        hasBillingIssue: Bool = false
    ) {
        self.kind = kind
        self.productIdentifier = productIdentifier
        self.expiresAt = expiresAt
        self.willRenew = willRenew
        self.isTrial = isTrial
        self.isFamilyShared = isFamilyShared
        self.hasBillingIssue = hasBillingIssue
    }

    /// The entitlement of builds that are not sold through the App Store: Pro is simply on.
    package static let included = ProEntitlement(kind: .included, productIdentifier: "included")
}

/// Whether this installation has Pro. `unknown` is the state before the first answer from the store and
/// reads as locked, so a free user never briefly sees paid features; a cached answer replaces it at launch.
package enum ProStatus: Equatable, Sendable {
    case unknown
    case free
    case pro(ProEntitlement)

    package var isPro: Bool {
        if case .pro = self { return true }
        return false
    }

    package var entitlement: ProEntitlement? {
        if case .pro(let entitlement) = self { return entitlement }
        return nil
    }
}

extension ProEntitlement {
    /// The one line the Pro screen shows under "Crucible Pro".
    package func summary(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch kind {
        case .included:
            return "Included in this build"
        case .lifetime:
            return isFamilyShared ? "Lifetime, shared by your family" : "Lifetime"
        case .subscription:
            let base = isTrial ? "Free trial" : "Annual"
            guard let expiresAt else { return base }
            let date = expiresAt.formatted(date: .abbreviated, time: .omitted)
            if hasBillingIssue { return "\(base) · payment problem, access until \(date)" }
            if willRenew { return "\(base) · renews \(date)" }
            return expiresAt > now ? "\(base) · ends \(date)" : "\(base) · ended \(date)"
        }
    }
}

/// What a store reports about the Pro entitlement, in a shape that has no store types in it.
package struct ProEntitlementSnapshot: Equatable, Sendable {
    package var isActive: Bool
    package var productIdentifier: String
    package var expirationDate: Date?
    package var willRenew: Bool
    package var isTrial: Bool
    package var isFamilyShared: Bool
    package var billingIssueDetectedAt: Date?

    package init(
        isActive: Bool,
        productIdentifier: String,
        expirationDate: Date?,
        willRenew: Bool,
        isTrial: Bool,
        isFamilyShared: Bool,
        billingIssueDetectedAt: Date?
    ) {
        self.isActive = isActive
        self.productIdentifier = productIdentifier
        self.expirationDate = expirationDate
        self.willRenew = willRenew
        self.isTrial = isTrial
        self.isFamilyShared = isFamilyShared
        self.billingIssueDetectedAt = billingIssueDetectedAt
    }
}

extension ProStatus {
    /// Free unless the snapshot is an active entitlement. An entitlement with no expiry is the lifetime unlock.
    package init(snapshot: ProEntitlementSnapshot?) {
        guard let snapshot, snapshot.isActive else {
            self = .free
            return
        }
        self = .pro(ProEntitlement(
            kind: snapshot.expirationDate == nil ? .lifetime : .subscription,
            productIdentifier: snapshot.productIdentifier,
            expiresAt: snapshot.expirationDate,
            willRenew: snapshot.willRenew,
            isTrial: snapshot.isTrial,
            isFamilyShared: snapshot.isFamilyShared,
            hasBillingIssue: snapshot.billingIssueDetectedAt != nil
        ))
    }
}
