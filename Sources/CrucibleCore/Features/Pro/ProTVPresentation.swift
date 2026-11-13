import Foundation

/// The words and the small decisions of Crucible Pro on Apple TV that are not drawing: when a lock shows, what the Settings
/// row says, why the paywall opened and how a restore ended. The tvOS screens only place them.
package enum ProTVPresentation {
    package struct Alert: Equatable, Sendable {
        package var title: String
        package var message: String
    }

    package static let pitch = String(localized: "Unlock full Statistics and Top Shelf")
    package static let manageSubscriptionText = String(localized: "To manage or cancel: Settings > Users & Accounts > your account > Subscriptions")

    /// Locks belong to installs that can buy Pro and do not have it. Source builds, which cannot sell anything, and Pro installs
    /// never show one; a status the store has not answered yet reads as locked, like `ProStatus.unknown`.
    package static func showsLocks(status: ProStatus, isStoreBacked: Bool) -> Bool {
        isStoreBacked && !status.isPro
    }

    /// Under "Crucible Pro" in the You list: the plan for a Pro user, the days left while the Pro Week runs, the pitch for everyone
    /// else.
    package static func rowSubtitle(for status: ProStatus, proWeekEndsAt: Date? = nil, now: Date = Date(), calendar: Calendar = .current) -> String {
        if let entitlement = status.entitlement { return entitlement.summary(now: now, calendar: calendar) }
        guard let proWeekEndsAt else { return pitch }
        return ProWeek.daysLeftText(until: proWeekEndsAt, now: now)
    }

    /// Why the paywall opened: the Pro Week around it, or the feature the user reached for. With neither, the viewer's own year
    /// so far when `facts` holds enough of it.
    package static func reasonLine(
        for request: PaywallRequest,
        proWeekEndsAt: Date?,
        facts: ProViewerFacts = ProViewerFacts(),
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        ProWeek.paywallLine(followsProWeek: request.followsProWeek, endsAt: proWeekEndsAt, isTV: true)
            ?? reasonLine(for: request.feature)
            ?? ProPersonalDetails.headline(facts, now: now, calendar: calendar)
    }

    /// Why the paywall opened, when the user reached for a feature.
    package static func reasonLine(for feature: ProFeature?) -> String? {
        guard let feature else { return nil }
        switch feature {
        case .fullStatistics: return String(localized: "Month, Year, All and the library filter are part of Crucible Pro.")
        case .unlimitedDownloads, .yearInReviewPoster, .topShelf, .manageRequests: return String(localized: "\(feature.title) is part of Crucible Pro.")
        }
    }

    /// The legal pages as plain text, each address on a line of its own so it never breaks mid-address: tvOS cannot open links.
    package static var legalText: String {
        let terms = ProLinks.termsOfUse.absoluteString
        let privacy = ProLinks.privacyPolicy.absoluteString
        return String(localized: "Terms of Use\n\(terms)\nPrivacy Policy\n\(privacy)")
    }

    /// `legalText` with a break opportunity after each slash of an address, so a column too narrow for the whole address wraps
    /// between path segments and never in the middle of a word. Screens show this; VoiceOver reads `legalText`.
    package static var legalDisplayText: String {
        legalText
            .replacingOccurrences(of: "/", with: "/\u{200B}")
            .replacingOccurrences(of: ":/\u{200B}/\u{200B}", with: "://")
    }

    /// What the Pro screen tells the user after Restore Purchases.
    @MainActor
    package static func restoreAlert(for outcome: ProRestoreOutcome, isPro: Bool) -> Alert {
        switch outcome {
        case .restored where isPro:
            return Alert(title: String(localized: "Crucible Pro Restored"), message: String(localized: "Your purchase is back on this Apple TV."))
        case .restored, .nothingToRestore:
            return Alert(title: String(localized: "Nothing to Restore"), message: PaywallModel.message(for: .nothingToRestore))
        case .failed(let failure):
            return Alert(title: String(localized: "Couldn\u{2019}t Restore"), message: PaywallModel.message(for: failure))
        }
    }
}
