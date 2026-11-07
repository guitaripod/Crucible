import Foundation

/// The shows whose Essentials choices hide something, per Plex Home profile, so the player knows without a
/// request whether Up Next has to consult a guide.
package enum EssentialsActiveShows {
    private static func key(_ profile: String) -> String { "essentials.active.\(profile)" }

    package static func contains(_ showRatingKey: String, defaults: UserDefaults = .standard, profile: String = HomeProfiles.active?.id ?? "account") -> Bool {
        (defaults.stringArray(forKey: key(profile)) ?? []).contains(showRatingKey)
    }

    package static func set(_ showRatingKey: String, active: Bool, defaults: UserDefaults = .standard, profile: String = HomeProfiles.active?.id ?? "account") {
        var keys = Set(defaults.stringArray(forKey: key(profile)) ?? [])
        if active { keys.insert(showRatingKey) } else { keys.remove(showRatingKey) }
        defaults.set(keys.sorted(), forKey: key(profile))
    }
}

/// Where a show's Essentials plan lives while the app runs: built when the show page loads, reused by Up Next,
/// and rebuilt from the server when Up Next needs one the show page never made.
package actor EssentialsCenter {
    package static let shared = EssentialsCenter()

    private struct Entry {
        let plan: EssentialsPlan
        let episodes: [PlexMetadata]
    }

    private var entries: [String: Entry] = [:]
    private let store: GuideStore

    package init(store: GuideStore = .shared) {
        self.store = store
    }

    /// The plan for `show` over `episodes` (every episode of the show), or nil when no guide covers it or its
    /// episodes do not line up with the guide.
    package func plan(show: PlexMetadata, episodes: [PlexMetadata]) async -> EssentialsPlan? {
        let ids = show.externalIDs
        guard !ids.isEmpty, let bundle = await store.bundle(), let guide = bundle.show(matching: ids) else { return nil }
        let choice = EssentialsChoices().choice(for: guide.slug)
        guard let plan = EssentialsPlan.make(guide: guide, episodes: episodes, choice: choice) else { return nil }
        entries[show.id] = Entry(plan: plan, episodes: episodes)
        return plan
    }

    /// Saves a person's choice for the show and returns the plan it gives.
    @discardableResult
    package func save(_ choice: EssentialsChoice, showRatingKey: String) -> EssentialsPlan? {
        guard let entry = entries[showRatingKey] else { return nil }
        EssentialsChoices().save(choice, for: entry.plan.guide.slug)
        EssentialsActiveShows.set(showRatingKey, active: choice.level != .all || choice.seenRetold)
        let plan = entry.plan.with(choice)
        entries[showRatingKey] = Entry(plan: plan, episodes: entry.episodes)
        return plan
    }

    package func cachedPlan(showRatingKey: String) -> EssentialsPlan? {
        entries[showRatingKey]?.plan
    }

    /// What Essentials says plays after `ratingKey`: nothing to say when the person's choices hide nothing in
    /// this show, otherwise the next episode they keep, or the end of the show.
    package enum Successor: Sendable {
        case notApplicable
        case next(PlexMetadata)
        case end
    }

    package func successor(after ratingKey: String, showRatingKey: String, api: APIClient) async -> Successor {
        guard EssentialsActiveShows.contains(showRatingKey) else { return .notApplicable }
        if entries[showRatingKey] == nil {
            guard let show = try? await api.requestContainer(.metadata(ratingKey: showRatingKey)).Metadata?.first,
                  let leaves = try? await api.requestContainer(.folderPath("/library/metadata/\(showRatingKey)/allLeaves")).Metadata else {
                return .notApplicable
            }
            _ = await plan(show: show, episodes: leaves.filter { $0.mediaType == "episode" })
        }
        guard let entry = entries[showRatingKey], entry.plan.numbers[ratingKey] != nil || entry.episodes.contains(where: { $0.id == ratingKey }) else {
            return .notApplicable
        }
        guard let next = entry.plan.next(after: ratingKey, in: entry.episodes) else { return .end }
        return .next(next)
    }
}
