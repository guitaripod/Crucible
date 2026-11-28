import Foundation

/// How much time the viewer has now; videos that need more are dimmed, not hidden, so the list stays whole.
package enum WatchLaterBudget: Int, CaseIterable, Sendable {
    case any = 0
    case quarterHour = 900
    case halfHour = 1800
    case hour = 3600
    case twoHours = 7200

    /// The time in seconds, nil for no limit.
    package var seconds: Double? { self == .any ? nil : Double(rawValue) }
}

/// The order of the videos inside each part of the guide.
package enum WatchLaterOrder: String, CaseIterable, Sendable {
    case recent, oldest, shortest, longest
}

/// Watch Later laid out as a guide: what the viewer already began first, then what is left by how long it takes, then
/// what is live or upcoming, and last what they have watched already.
package struct WatchLaterGuide: Sendable {
    /// A band of the guide.
    package enum Part: String, CaseIterable, Sendable {
        case resume, underTen, tenToThirty, thirtyToSixty, overHour, unknown, live, watched
    }

    /// One saved video with what the guide knows of it.
    package struct Item: Sendable, Hashable {
        package var entry: WebEntry
        package var watch: WebWatch?
        /// Seconds still to watch, nil when the length is not known.
        package var remaining: Double?
        /// Whether it fits the time the viewer has and is there to watch.
        package var fits: Bool
        package var isWatched: Bool
    }

    package struct Section: Sendable, Hashable {
        package var part: Part
        package var items: [Item]

        /// What the section takes to watch, counting only videos whose length is known.
        package var remaining: Double { items.reduce(0) { $0 + ($1.remaining ?? 0) } }
    }

    package let sections: [Section]
    package let budget: WatchLaterBudget

    package init(saved: [WebEntry], watch: (String) -> WebWatch?, budget: WatchLaterBudget = .any, order: WatchLaterOrder = .recent) {
        self.budget = budget
        var ordered = saved
        switch order {
        case .recent: break
        case .oldest: ordered.reverse()
        case .shortest: ordered = Self.sorted(saved) { $0 < $1 }
        case .longest: ordered = Self.sorted(saved) { $0 > $1 }
        }
        var bands: [Part: [Item]] = [:]
        for entry in ordered {
            let seen = watch(entry.id)
            let item = Self.item(entry, watch: seen, budget: budget)
            bands[Self.part(of: item), default: []].append(item)
        }
        bands[.resume]?.sort { ($0.watch?.watchedAt ?? .distantPast) > ($1.watch?.watchedAt ?? .distantPast) }
        sections = Part.allCases.compactMap { part in bands[part].map { Section(part: part, items: $0) } }
    }

    /// Every saved video in the guide's order.
    package var items: [Item] { sections.flatMap(\.items) }

    package var isEmpty: Bool { sections.isEmpty }

    /// Seconds left to watch across everything not watched yet.
    package var remaining: Double { sections.filter { $0.part != .watched }.reduce(0) { $0 + $1.remaining } }

    /// The videos worth queueing: not watched, not live or upcoming, not a Short, and fitting the time the viewer has.
    package var queue: [WebEntry] {
        items.filter { $0.fits && !$0.isWatched && $0.entry.kind == .video && !$0.entry.isLive && !$0.entry.isUpcoming && !$0.entry.isShort }
            .map(\.entry)
    }

    /// How many videos still to watch fit the time the viewer has.
    package var fitting: Int { items.filter { $0.fits && !$0.isWatched }.count }

    /// How many videos still to watch.
    package var unwatched: Int { items.filter { !$0.isWatched }.count }

    package var watched: [WebEntry] { sections.first { $0.part == .watched }?.items.map(\.entry) ?? [] }

    /// The videos too long for the time the viewer has.
    package var overBudget: [WebEntry] { items.filter { !$0.fits && !$0.isWatched }.map(\.entry) }

    private static func sorted(_ saved: [WebEntry], by areInOrder: (Double, Double) -> Bool) -> [WebEntry] {
        let known = saved.enumerated().filter { ($0.element.duration ?? 0) > 0 }
        let unknown = saved.filter { ($0.duration ?? 0) <= 0 }
        let sortedKnown = known.sorted { lhs, rhs in
            let (a, b) = (lhs.element.duration ?? 0, rhs.element.duration ?? 0)
            return a == b ? lhs.offset < rhs.offset : areInOrder(a, b)
        }
        return sortedKnown.map(\.element) + unknown
    }

    private static func item(_ entry: WebEntry, watch: WebWatch?, budget: WatchLaterBudget) -> Item {
        let length = (entry.duration ?? 0) > 0 ? entry.duration : (watch?.duration ?? 0) > 0 ? watch?.duration : nil
        let watched = watch?.isFinished ?? false
        let left = length.map { watched ? 0 : max($0 - (watch?.position ?? 0), 0) }
        let fits = !entry.isUpcoming && (budget.seconds.map { limit in left.map { $0 <= limit } ?? true } ?? true)
        return Item(entry: entry, watch: watch, remaining: entry.isLive ? nil : left, fits: fits, isWatched: watched)
    }

    private static func part(of item: Item) -> Part {
        if item.isWatched { return .watched }
        if item.entry.isLive || item.entry.isUpcoming { return .live }
        if let watch = item.watch, watch.position >= WebLibrary.worthResuming { return .resume }
        switch item.entry.duration ?? item.watch?.duration ?? 0 {
        case ..<1: return .unknown
        case ..<600: return .underTen
        case ..<1800: return .tenToThirty
        case ..<3600: return .thirtyToSixty
        default: return .overHour
        }
    }
}
