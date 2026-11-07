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
        guard let entry = await entry(showRatingKey: showRatingKey, api: api),
              entry.plan.numbers[ratingKey] != nil || entry.episodes.contains(where: { $0.id == ratingKey }) else {
            return .notApplicable
        }
        guard let next = entry.plan.next(after: ratingKey, in: entry.episodes) else { return .end }
        return .next(next)
    }

    /// `/hubs` the way Home and the Top Shelf show it: an episode nobody has started that the person's choices hide
    /// gives way to the next episode they keep, or leaves when the show has none left. Episodes already started stay.
    package func followingChoices(_ container: PlexMediaContainer, api: APIClient) async -> PlexMediaContainer {
        guard var hubs = container.Hub else { return container }
        var changed = false
        for index in hubs.indices {
            guard let items = hubs[index].Metadata else { continue }
            var kept: [PlexMetadata] = []
            for item in items {
                let replacement = await following(item, api: api)
                if replacement?.id != item.id { changed = true }
                if let replacement, !kept.contains(where: { $0.id == replacement.id }) { kept.append(replacement) }
            }
            hubs[index].Metadata = kept
        }
        guard changed else { return container }
        var adjusted = container
        adjusted.Hub = hubs
        return adjusted
    }

    /// The episode Home shows for `item`: itself, the next one the person keeps, or nil when the show has none left.
    private func following(_ item: PlexMetadata, api: APIClient) async -> PlexMetadata? {
        guard item.mediaType == "episode", (item.viewOffset ?? 0) == 0, let show = item.grandparentRatingKey,
              EssentialsActiveShows.contains(show),
              let entry = await entry(showRatingKey: show, api: api), entry.plan.hides(item.id) else { return item }
        return entry.plan.next(after: item.id, in: entry.episodes)
    }

    /// The show's cached plan, built from the server the first time something other than the show page needs it.
    private func entry(showRatingKey: String, api: APIClient) async -> Entry? {
        if entries[showRatingKey] == nil {
            guard let show = try? await api.requestContainer(.metadata(ratingKey: showRatingKey)).Metadata?.first,
                  let leaves = try? await api.requestContainer(.folderPath("/library/metadata/\(showRatingKey)/allLeaves")).Metadata else {
                return nil
            }
            _ = await plan(show: show, episodes: leaves.filter { $0.mediaType == "episode" })
        }
        return entries[showRatingKey]
    }

    /// `/hubs` with the person's Essentials choices applied, for Home, the launch and the Top Shelf.
    package static func hubs(api: APIClient) async throws -> PlexMediaContainer {
        await shared.followingChoices(try await api.requestContainer(.hubs()), api: api)
    }
}
