import Foundation

/// What the welcome says to someone whose library has just opened for the first time on this device (a new install, or the first
/// since the app's data was cleared): where they stand with Crucible Pro, and what Trakt would add. Every platform lays the same
/// plan out its own way, and lays it out again when the store or Trakt answers while it is on screen.
package struct WelcomePlan: Equatable, Sendable {
    package enum Standing: Equatable, Sendable {
        /// The store has not answered yet.
        case checking
        /// Free, with the Pro Week still ahead: the first film or episode watched to the end opens it.
        case freeWeekAhead
        /// Free, inside the Pro Week.
        case proWeek(endsAt: Date)
        /// Free, the Pro Week already used on this device.
        case free
        /// A free trial of Pro, ending at the date the store gives.
        case trial(endsAt: Date?)
        /// Pro bought for good or yearly, or shared by the family.
        case pro(familyShared: Bool)
        /// A build that is not sold through the App Store, where everything is open.
        case included
    }

    package enum TraktStep: Equatable, Sendable {
        /// Trakt is not connected: what it adds, and Connect Trakt.
        case invite
        /// Trakt signed Crucible out: Connect Again.
        case reconnect
        /// Trakt is connected, as the account named when Trakt has said.
        case connected(username: String?)
    }

    package let standing: Standing
    /// Nil where Trakt cannot be connected: a build without Trakt, or a restricted Home profile.
    package let trakt: TraktStep?

    package init(standing: Standing, trakt: TraktStep?) {
        self.standing = standing
        self.trakt = trakt
    }

    package init(status: ProStatus, isStoreBacked: Bool, proWeek: ProWeek.Phase, trakt: TraktAccount.Status) {
        self.init(
            standing: Self.standing(status: status, isStoreBacked: isStoreBacked, proWeek: proWeek),
            trakt: Self.traktStep(trakt)
        )
    }

    package static func standing(status: ProStatus, isStoreBacked: Bool, proWeek: ProWeek.Phase) -> Standing {
        guard isStoreBacked else { return .included }
        switch status {
        case .unknown:
            return .checking
        case .pro(let entitlement):
            if entitlement.kind == .included { return .included }
            if entitlement.isTrial { return .trial(endsAt: entitlement.expiresAt) }
            return .pro(familyShared: entitlement.isFamilyShared)
        case .free:
            switch proWeek {
            case .notStarted: return .freeWeekAhead
            case .active(let endsAt): return .proWeek(endsAt: endsAt)
            case .ended: return .free
            }
        }
    }

    package static func traktStep(_ status: TraktAccount.Status) -> TraktStep? {
        switch status {
        case .disconnected: return .invite
        case .needsReconnect: return .reconnect
        case .connected(let profile): return .connected(username: profile?.username)
        case .unavailable, .restricted: return nil
        }
    }

    /// Someone who bought Pro is thanked with a success haptic as the welcome opens.
    package var celebrates: Bool {
        if case .pro = standing { return true }
        return false
    }

    /// Only a free viewer whose Pro Week is behind them is offered a look at Crucible Pro; the week ahead is the better offer.
    package var offersPro: Bool {
        standing == .free
    }

    /// Whether everything in Pro is open now, so the welcome lists what Pro holds instead of what the free app does.
    package var listsProFeatures: Bool {
        switch standing {
        case .proWeek, .trial, .pro, .included: return true
        case .checking, .freeWeekAhead, .free: return false
        }
    }

    package var standingTitle: String { WelcomeCopy.title(of: standing) }
    package var standingMessage: String { WelcomeCopy.message(of: standing) }
    package var standingSymbol: String { WelcomeCopy.symbol(of: standing) }

    /// What the free app does, for a welcome that does not list Pro's features. Downloads are listed only where they exist.
    package func freeHighlights(includingDownloads: Bool) -> [WelcomeCopy.Highlight] {
        guard !listsProFeatures else { return [] }
        return WelcomeCopy.freeHighlights(includingDownloads: includingDownloads)
    }
}
