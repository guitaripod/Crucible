import Foundation

/// A one-time note to the viewer about Crucible Pro, shown on Apple TV at the two moments it is worth something: after the first
/// finished video, and shortly before a free trial ends.
package struct ProMoment: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        case firstFinish
        case trialEnding(Date)
    }

    package enum Action: Equatable, Sendable {
        case openStatistics
        case seePro
        case acknowledge
    }

    package var kind: Kind
    package var title: String
    package var message: String
    package var action: Action
    package var actionTitle: String
}

/// What each Pro moment says and when it is due. The screens only place the words; nothing here touches the store.
package enum ProTVMoments {
    package static let trialWarningWindow: TimeInterval = 2 * 24 * 60 * 60

    /// After the first finished video: a free viewer is told what Pro adds, a trial viewer is pointed at what the trial unlocked.
    /// Nothing for a paid Pro viewer, a source build, the demo, or a store that has not answered yet.
    package static func firstFinish(status: ProStatus, isStoreBacked: Bool, isDemo: Bool) -> ProMoment? {
        guard isStoreBacked, !isDemo else { return nil }
        switch status {
        case .unknown:
            return nil
        case .free:
            return ProMoment(
                kind: .firstFinish,
                title: "Go further with Crucible Pro",
                message: "Full Statistics for every range and library, and Top Shelf with Continue Watching on the Apple TV Home screen. The yearly plan starts with a 14-day free trial.",
                action: .seePro,
                actionTitle: "See Crucible Pro"
            )
        case .pro(let entitlement):
            guard entitlement.isTrial else { return nil }
            return ProMoment(
                kind: .firstFinish,
                title: "Your Crucible Pro trial is on",
                message: "Statistics now covers every range and library, and Top Shelf shows Continue Watching on the Apple TV Home screen.",
                action: .openStatistics,
                actionTitle: "Open Statistics"
            )
        }
    }

    /// Within two days of the end of a free trial: the date, what happens then and, when there is watch time, what Statistics holds.
    package static func trialEnding(status: ProStatus, weekWatchSeconds: Int?, now: Date = Date()) -> ProMoment? {
        guard
            let entitlement = status.entitlement,
            entitlement.kind == .subscription,
            entitlement.isTrial,
            let endsAt = entitlement.expiresAt,
            endsAt > now,
            endsAt.timeIntervalSince(now) <= trialWarningWindow
        else { return nil }
        let date = endsAt.formatted(date: .abbreviated, time: .omitted)
        var lines = [
            entitlement.willRenew
                ? "Your free trial ends on \(date) and Crucible Pro then renews yearly."
                : "Your free trial ends on \(date) and Crucible Pro will not renew."
        ]
        if let weekWatchSeconds, weekWatchSeconds > 0 {
            lines.append("This week you watched \(Formatters.duration(Double(weekWatchSeconds))); full Statistics keeps every week.")
        }
        lines.append(entitlement.willRenew ? ProTVPresentation.manageSubscriptionText : "Full Statistics and Top Shelf lock again after that date.")
        return ProMoment(
            kind: .trialEnding(endsAt),
            title: "Your free trial ends soon",
            message: lines.joined(separator: "\n"),
            action: .acknowledge,
            actionTitle: "OK"
        )
    }
}

/// Remembers which Pro moments were shown, so each appears once: the first-finish note once per install, the trial note once per
/// trial end date.
package struct ProMomentLedger {
    private static let firstFinishKey = "proMoment.firstFinishShown"
    private static let trialEndingKey = "proMoment.trialEndingShown"

    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    package func hasShown(_ kind: ProMoment.Kind) -> Bool {
        switch kind {
        case .firstFinish:
            return defaults.bool(forKey: Self.firstFinishKey)
        case .trialEnding(let endsAt):
            return defaults.object(forKey: Self.trialEndingKey) as? TimeInterval == endsAt.timeIntervalSince1970.rounded()
        }
    }

    package func markShown(_ kind: ProMoment.Kind) {
        switch kind {
        case .firstFinish:
            defaults.set(true, forKey: Self.firstFinishKey)
        case .trialEnding(let endsAt):
            defaults.set(endsAt.timeIntervalSince1970.rounded(), forKey: Self.trialEndingKey)
        }
    }

    /// Forgets every shown moment, for a debug launch that starts as a new install.
    package func reset() {
        defaults.removeObject(forKey: Self.firstFinishKey)
        defaults.removeObject(forKey: Self.trialEndingKey)
    }
}
