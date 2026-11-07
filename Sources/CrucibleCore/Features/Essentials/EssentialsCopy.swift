import Foundation

/// The words Essentials uses on every screen, so the iPhone, iPad and Apple TV say the same thing.
package enum EssentialsCopy {
    /// "8 h 6 min", "45 min".
    package static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: max(60, seconds)) ?? ""
    }

    /// The bar's title: the level in use.
    package static func barTitle(_ plan: EssentialsPlan) -> String {
        plan.choice.level.title
    }

    /// "110 of 131 episodes · saves 8 h 6 min", or "131 episodes" when nothing is hidden.
    package static func barDetail(_ plan: EssentialsPlan) -> String {
        let hidden = plan.preview(plan.choice)
        guard hidden.hidden > 0 else {
            return String(localized: "\(plan.episodeCount) episodes", comment: "Essentials bar when nothing is hidden, e.g. 131 episodes")
        }
        return String(localized: "\(plan.shownCount) of \(plan.episodeCount) episodes · saves \(duration(hidden.seconds))", comment: "Essentials bar, e.g. 110 of 131 episodes · saves 8 h 6 min")
    }

    /// "From the Dragon Ball Wiki and Wikipedia · CC BY-SA", the attribution the sources' licence asks for.
    package static func sourceLine(_ guide: GuideShow) -> String {
        let names = guide.sources.map(\.name)
        let list = ListFormatter.localizedString(byJoining: names.isEmpty ? ["Crucible Guides"] : names)
        return String(localized: "From \(list) · CC BY-SA", comment: "Attribution under Essentials, naming the wikis the episode guide comes from")
    }

    /// The menu's subtitle for a level: how many episodes it hides and the time that saves.
    package static func levelSubtitle(_ plan: EssentialsPlan, level: EssentialsLevel) -> String? {
        var choice = plan.choice
        choice.level = level
        let preview = plan.preview(choice)
        guard level != .all else { return String(localized: "Every episode, in order", comment: "Subtitle of the All Episodes level") }
        guard preview.hidden > 0 else { return nil }
        return String(localized: "Hides \(preview.hidden) · saves \(duration(preview.seconds))", comment: "Subtitle of an Essentials level, e.g. Hides 21 · saves 8 h 6 min")
    }

    /// "I've Seen the Films", naming what the retold stretch retells.
    package static func retoldTitle(_ range: GuideRange) -> String {
        String(localized: "I've Seen \(ListFormatter.localizedString(byJoining: range.retells))", comment: "Essentials toggle that hides episodes retelling films the viewer has seen, e.g. I've Seen Battle of Gods and Resurrection 'F'")
    }

    package static func retoldSubtitle(_ range: GuideRange) -> String {
        String(localized: "Episodes \(range.from)–\(range.to) retell them", comment: "Subtitle of the I've Seen toggle, e.g. Episodes 1–27 retell them")
    }

    /// The episode row's note, when Essentials has something to say about it.
    package static func episodeNote(_ plan: EssentialsPlan, ratingKey: String) -> String? {
        if plan.hides(ratingKey) {
            if plan.range(of: ratingKey) != nil, plan.choice.seenRetold { return String(localized: "Skipped · retells a film", comment: "Episode row note: hidden because it retells a film the viewer has seen") }
            return String(localized: "Skipped · anime-only", comment: "Episode row note: hidden because it adapts no manga chapter")
        }
        if plan.wouldHide(ratingKey) { return String(localized: "Kept", comment: "Episode row note: the viewer kept an episode Essentials would hide") }
        return nil
    }

    /// Whether to offer Essentials once for this show: long enough, something to hide, not offered yet.
    package static func shouldOffer(_ plan: EssentialsPlan) -> Bool {
        guard !plan.choice.offered, plan.choice.level == .all, plan.episodeCount >= EssentialsPlan.offerThreshold else { return false }
        return plan.preview(EssentialsChoice(level: .skipAnimeOnly)).hidden > 0
    }

    package static func offerTitle(_ plan: EssentialsPlan, show: String) -> String {
        String(localized: "\(show) has \(plan.episodeCount) episodes.", comment: "Essentials offer, e.g. Dragon Ball Super has 131 episodes.")
    }

    package static func offerMessage(_ plan: EssentialsPlan) -> String {
        let preview = plan.preview(EssentialsChoice(level: .skipAnimeOnly))
        return String(localized: "Skip the \(preview.hidden) anime-only episodes and save \(duration(preview.seconds))?", comment: "Essentials offer, e.g. Skip the 21 anime-only episodes and save 8 h 6 min?")
    }

    package static let offerAccept = String(localized: "Skip Them", comment: "Essentials offer button that turns on Skip Anime-Only")
    package static let offerDecline = String(localized: "Watch Everything", comment: "Essentials offer button that keeps every episode")
    package static let showSkipped = String(localized: "Show Skipped Episodes", comment: "Toggle that lists the episodes Essentials hides")
    package static let keep = String(localized: "Keep This Episode", comment: "Action that brings back one episode Essentials hides")
    package static let hideAgain = String(localized: "Skip This Episode Again", comment: "Action that lets Essentials hide an episode the viewer had kept")
    package static let aboutGuides = String(localized: "About These Guides", comment: "Menu item that opens the Crucible Guides page naming its sources")
    package static let title = String(localized: "Essentials", comment: "Name of the feature that hides anime-only episodes of long shows")
    package static let guidesURL = URL(string: "https://github.com/guitaripod/crucible-guides")!
}

/// Spoiler Shield: unwatched episodes of a show keep their number but lose their title, synopsis and still.
package enum SpoilerShield {
    private static func key(_ profile: String) -> String { "spoiler_shield.\(profile)" }

    package static func isOn(_ showRatingKey: String, defaults: UserDefaults = .standard, profile: String = HomeProfiles.active?.id ?? "account") -> Bool {
        (defaults.stringArray(forKey: key(profile)) ?? []).contains(showRatingKey)
    }

    package static func set(_ showRatingKey: String, on: Bool, defaults: UserDefaults = .standard, profile: String = HomeProfiles.active?.id ?? "account") {
        var keys = Set(defaults.stringArray(forKey: key(profile)) ?? [])
        if on { keys.insert(showRatingKey) } else { keys.remove(showRatingKey) }
        defaults.set(keys.sorted(), forKey: key(profile))
    }

    package static let title = String(localized: "Spoiler Shield", comment: "Toggle that hides the titles, synopses and stills of unwatched episodes")
    package static let subtitle = String(localized: "Hides titles, synopses and stills of episodes you haven't seen", comment: "Subtitle of the Spoiler Shield toggle")

    /// "Episode 77", what a shielded row says instead of its title.
    package static func title(for episode: PlexMetadata) -> String {
        episode.index.map { String(localized: "Episode \($0)", comment: "A shielded episode's title, e.g. Episode 77") } ?? String(localized: "Episode", comment: "A shielded episode's title when it has no number")
    }
}

/// Highlights: for a show no guide covers, the best-rated episodes of each season by Plex's own audience ratings.
package enum Highlights {
    /// The ids of the top quarter of each season's rated episodes, at least one per season; empty when too few are rated.
    package static func keys(in episodes: [PlexMetadata]) -> Set<String> {
        let rated = episodes.filter { ($0.audienceRating ?? 0) > 0 }
        guard rated.count >= 4, Double(rated.count) >= Double(episodes.count) * 0.5 else { return [] }
        var keys: Set<String> = []
        for (_, season) in Dictionary(grouping: rated, by: { $0.parentIndex ?? 0 }) {
            let count = max(1, Int((Double(season.count) / 4).rounded(.up)))
            let best = season.sorted { ($0.audienceRating ?? 0) > ($1.audienceRating ?? 0) }.prefix(count)
            keys.formUnion(best.map(\.id))
        }
        return keys
    }

    package static let title = String(localized: "Highlights", comment: "Episode filter that keeps each season's best-rated episodes")
    package static let subtitle = String(localized: "Each season's best-rated episodes", comment: "Subtitle of the Highlights filter")
    package static let note = String(localized: "Highlight", comment: "Episode row note: one of the season's best-rated episodes")
}
