import Foundation

/// How much of a long show a person wants to watch.
package enum EssentialsLevel: String, Sendable, CaseIterable, Codable {
    case all
    case skipAnimeOnly

    package var title: String {
        switch self {
        case .all: return String(localized: "All Episodes", comment: "Essentials level that shows every episode")
        case .skipAnimeOnly: return String(localized: "Skip Anime-Only", comment: "Essentials level that hides episodes the anime made up, which adapt no manga chapter")
        }
    }
}

/// A person's Essentials choices for one show.
package struct EssentialsChoice: Sendable, Equatable, Codable {
    package var level: EssentialsLevel = .all
    package var seenRetold = false
    package var kept: Set<Int> = []
    package var offered = false

    package init(level: EssentialsLevel = .all, seenRetold: Bool = false, kept: Set<Int> = [], offered: Bool = false) {
        self.level = level
        self.seenRetold = seenRetold
        self.kept = kept
        self.offered = offered
    }
}

/// Where each person's choices are kept: on this device, per Plex Home profile and show.
package struct EssentialsChoices {
    private let defaults: UserDefaults
    private let profile: String

    package init(defaults: UserDefaults = .standard, profile: String = HomeProfiles.active?.id ?? "account") {
        self.defaults = defaults
        self.profile = profile
    }

    private func key(_ slug: String) -> String { "essentials.\(profile).\(slug)" }

    package func choice(for slug: String) -> EssentialsChoice {
        guard let data = defaults.data(forKey: key(slug)), let choice = try? JSONDecoder().decode(EssentialsChoice.self, from: data) else {
            return EssentialsChoice()
        }
        return choice
    }

    package func save(_ choice: EssentialsChoice, for slug: String) {
        guard let data = try? JSONEncoder().encode(choice) else { return }
        defaults.set(data, forKey: key(slug))
    }
}

/// One show's guide laid over its episodes in a Plex library: which ones a person's choices hide, how many
/// remain, and the time that saves.
package struct EssentialsPlan: Sendable, Equatable {
    package let guide: GuideShow
    /// Each library episode's number in the guide.
    package let numbers: [String: Int]
    package let choice: EssentialsChoice
    private let runtimes: [String: Double]

    package init(guide: GuideShow, numbers: [String: Int], choice: EssentialsChoice, runtimes: [String: Double] = [:]) {
        self.guide = guide
        self.numbers = numbers
        self.choice = choice
        self.runtimes = runtimes
    }

    /// Lays `guide` over `episodes` (every episode of the show, specials excluded), or nil when they do not line up.
    package static func make(guide: GuideShow, episodes: [PlexMetadata], choice: EssentialsChoice) -> EssentialsPlan? {
        guard let numbers = EpisodeAlignment.numbers(guide: guide, episodes: episodes) else { return nil }
        let runtimes = Dictionary(episodes.map { ($0.id, $0.durationSecs) }, uniquingKeysWith: { a, _ in a })
        return EssentialsPlan(guide: guide, numbers: numbers, choice: choice, runtimes: runtimes)
    }

    package func with(_ choice: EssentialsChoice) -> EssentialsPlan {
        EssentialsPlan(guide: guide, numbers: numbers, choice: choice, runtimes: runtimes)
    }

    private var kinds: [Int: GuideKind] { Dictionary(guide.episodes.map { ($0.n, $0.kind) }, uniquingKeysWith: { a, _ in a }) }

    /// The guide's kind for a library episode, when the guide knows it.
    package func kind(of ratingKey: String) -> GuideKind? {
        numbers[ratingKey].flatMap { kinds[$0] }
    }

    package func number(of ratingKey: String) -> Int? { numbers[ratingKey] }

    /// The range a library episode falls in, when a source says that stretch retells something.
    package func range(of ratingKey: String) -> GuideRange? {
        guard let n = numbers[ratingKey] else { return nil }
        return guide.ranges.first { $0.contains(n) }
    }

    /// Whether these choices hide the episode. Anime-only episodes inside a retold range stay until the
    /// person says they have seen what is retold, since they carry that story here.
    package func hides(_ ratingKey: String) -> Bool {
        guard let n = numbers[ratingKey], !choice.kept.contains(n) else { return false }
        if choice.seenRetold, guide.ranges.contains(where: { $0.contains(n) }) { return true }
        guard choice.level == .skipAnimeOnly, let kind = kinds[n], kind.isAnimeOnly else { return false }
        return !guide.ranges.contains { $0.contains(n) }
    }

    /// Whether the level and range would hide the episode, ignoring "Keep this one", so a kept episode can be told apart.
    package func wouldHide(_ ratingKey: String) -> Bool {
        guard let n = numbers[ratingKey] else { return false }
        var unkept = choice
        unkept.kept.remove(n)
        return with(unkept).hides(ratingKey)
    }

    package var episodeCount: Int { numbers.count }
    package var hiddenKeys: Set<String> { Set(numbers.keys.filter(hides)) }
    package var shownCount: Int { episodeCount - hiddenKeys.count }

    /// How many episodes and how much watch time a choice would hide, for the offer and the level menu.
    package func preview(_ choice: EssentialsChoice) -> (hidden: Int, seconds: Double) {
        let plan = with(choice)
        let keys = plan.hiddenKeys
        return (keys.count, keys.reduce(0) { $0 + (runtimes[$1] ?? 0) })
    }

    /// The episode to play after `ratingKey`: the next one in order that these choices keep.
    package func next(after ratingKey: String, in episodes: [PlexMetadata]) -> PlexMetadata? {
        let ordered = EpisodeOrder.sorted(episodes)
        guard let index = ordered.firstIndex(where: { $0.id == ratingKey }) else { return nil }
        return ordered[(index + 1)...].first { !hides($0.id) }
    }

    /// Whether a show is long enough that the one-time offer is worth making.
    package static let offerThreshold = 40
}

/// Lines a guide's numbering up with a library's episodes. Plex may order a show by air date, DVD order or
/// one absolute season; the guide numbers episodes absolutely. Positions are tried first and checked
/// against air dates; air dates alone are the fallback; anything that does not agree gives nothing.
package enum EpisodeAlignment {
    package static func numbers(guide: GuideShow, episodes: [PlexMetadata]) -> [String: Int]? {
        let regular = EpisodeOrder.sorted(episodes.filter { ($0.parentIndex ?? 1) > 0 })
        guard !regular.isEmpty, !guide.episodes.isEmpty else { return nil }
        let byNumber = Dictionary(guide.episodes.map { ($0.n, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = guide.episodes.map(\.n).sorted()

        var positional: [String: Int] = [:]
        for (index, episode) in regular.enumerated() where index < ordered.count {
            positional[episode.id] = ordered[index]
        }
        if agrees(positional, regular: regular, byNumber: byNumber) { return positional }

        var dated: [String: Int] = [:]
        let byDate = Dictionary(grouping: guide.episodes.filter { $0.aired != nil }, by: { $0.aired! })
        for episode in regular {
            guard let day = episode.originallyAvailableAt.flatMap(Self.day) else { continue }
            if let match = byDate[day], match.count == 1 { dated[episode.id] = match[0].n }
        }
        guard Double(dated.count) >= Double(regular.count) * 0.8 else { return nil }
        return dated
    }

    /// Whether positions line up with air dates: most episodes that both sides date must land within two days.
    private static func agrees(_ mapping: [String: Int], regular: [PlexMetadata], byNumber: [Int: GuideEpisode]) -> Bool {
        var compared = 0
        var matched = 0
        for episode in regular {
            guard let n = mapping[episode.id],
                  let plexDay = episode.originallyAvailableAt.flatMap(Self.date),
                  let guideDay = byNumber[n]?.aired.flatMap(Self.date) else { continue }
            compared += 1
            if abs(plexDay.timeIntervalSince(guideDay)) <= 2 * 86_400 { matched += 1 }
        }
        if compared == 0 { return regular.count == byNumber.count }
        return Double(matched) / Double(compared) >= 0.7
    }

    private static func day(_ text: String) -> String? {
        String(text.prefix(10)).count == 10 ? String(text.prefix(10)) : nil
    }

    private static func date(_ text: String) -> Date? {
        guard let day = day(text) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }
}
