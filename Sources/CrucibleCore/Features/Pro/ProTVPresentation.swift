import Foundation

/// The words and the small decisions of Crucible Pro on Apple TV that are not drawing: when a lock shows, what the Settings
/// row says, why the paywall opened and how a restore ended. The tvOS screens only place them.
package enum ProTVPresentation {
    package struct Alert: Equatable, Sendable {
        package var title: String
        package var message: String
    }

    package static let pitch = "Unlock full Statistics and Top Shelf"
    package static let manageSubscriptionText = "To manage or cancel: Settings > Users & Accounts > your account > Subscriptions"

    /// Locks belong to installs that can buy Pro and do not have it. Source builds, which cannot sell anything, and Pro installs
    /// never show one; a status the store has not answered yet reads as locked, like `ProStatus.unknown`.
    package static func showsLocks(status: ProStatus, isStoreBacked: Bool) -> Bool {
        isStoreBacked && !status.isPro
    }

    /// Under "Crucible Pro" in the You list: the plan for a Pro user, the pitch for everyone else.
    package static func rowSubtitle(for status: ProStatus, now: Date = Date(), calendar: Calendar = .current) -> String {
        status.entitlement?.summary(now: now, calendar: calendar) ?? pitch
    }

    /// Why the paywall opened, when the user reached for a feature.
    package static func reasonLine(for feature: ProFeature?) -> String? {
        guard let feature else { return nil }
        switch feature {
        case .fullStatistics: return "Month, Year, All and the library filter are part of Crucible Pro."
        case .unlimitedDownloads, .yearInReviewPoster, .topShelf: return "\(feature.title) is part of Crucible Pro."
        }
    }

    /// The legal pages as plain text, each address on a line of its own so it never breaks mid-address: tvOS cannot open links.
    package static var legalText: String {
        "Terms of Use\n\(ProLinks.termsOfUse.absoluteString)\nPrivacy Policy\n\(ProLinks.privacyPolicy.absoluteString)"
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
            return Alert(title: "Crucible Pro Restored", message: "Your purchase is back on this Apple TV.")
        case .restored, .nothingToRestore:
            return Alert(title: "Nothing to Restore", message: PaywallModel.message(for: .nothingToRestore))
        case .failed(let failure):
            return Alert(title: "Couldn\u{2019}t Restore", message: PaywallModel.message(for: failure))
        }
    }
}
