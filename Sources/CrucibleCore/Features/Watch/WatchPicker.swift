import Foundation

/// A film or series of the person's library as What to Watch reads it.
package struct WatchTitle: Equatable, Sendable, Identifiable {
    package enum Kind: String, Sendable {
        case movie, show
    }

    package enum Seen: String, Sendable {
        case unseen, started, seen
    }

    package let id: String
    package let kind: Kind
    package let title: String
    package let year: Int?
    package let genres: [String]
    package let minutes: Int?
    package let rating: Double?
    package let contentRating: String?
    package let seen: Seen
    package let addedAt: Int

    package init(id: String, kind: Kind, title: String, year: Int? = nil, genres: [String] = [], minutes: Int? = nil, rating: Double? = nil, contentRating: String? = nil, seen: Seen = .unseen, addedAt: Int = 0) {
        self.id = id
        self.kind = kind
        self.title = title
        self.year = year
        self.genres = genres
        self.minutes = minutes
        self.rating = rating
        self.contentRating = contentRating
        self.seen = seen
        self.addedAt = addedAt
    }

    /// A film or series from Plex, or nil for anything else. A film left partway counts as started. A series counts
    /// as seen once every episode is, and as started when some are; its length is one episode's.
    package init?(_ item: PlexMetadata) {
        guard let kind = Kind(rawValue: item.mediaType), !item.id.isEmpty else { return nil }
        let seen: Seen
        switch kind {
        case .movie: seen = item.isWatched ? .seen : ((item.viewOffset ?? 0) > 0 ? .started : .unseen)
        case .show:
            let watched = item.viewedLeafCount ?? 0
            seen = watched == 0 ? .unseen : (watched >= (item.leafCount ?? Int.max) ? .seen : .started)
        }
        self.init(
            id: item.id, kind: kind, title: item.title, year: item.year,
            genres: (item.Genre ?? []).prefix(3).map(\.tag),
            minutes: item.duration.map { max(1, Int((Double($0) / 60_000).rounded())) },
            rating: item.audienceRating ?? item.rating, contentRating: item.contentRating, seen: seen, addedAt: item.addedAt ?? 0)
    }
}

/// The limits a request states, which code applies before the model chooses: a running time, an era, a kind, whether
/// it must be new to the person. The service's plan alias writes it; every figure is checked here before it is used.
package struct WatchPlan: Equatable, Sendable {
    package enum Watched: String, Sendable {
        case unseen, seen, any
    }

    package var kind: WatchTitle.Kind?
    package var watched: Watched
    package var maxMinutes: Int?
    package var minMinutes: Int?
    package var fromYear: Int?
    package var toYear: Int?
    package var family: Bool
    package var count: Int

    package init(kind: WatchTitle.Kind? = nil, watched: Watched = .any, maxMinutes: Int? = nil, minMinutes: Int? = nil, fromYear: Int? = nil, toYear: Int? = nil, family: Bool = false, count: Int = WatchPicker.usualCount) {
        self.kind = kind
        self.watched = watched
        self.maxMinutes = maxMinutes
        self.minMinutes = minMinutes
        self.fromYear = fromYear
        self.toYear = toYear
        self.family = family
        self.count = count
    }
}

/// One title the model chose, with its sentence on why it fits.
package struct WatchPick: Equatable, Sendable, Identifiable {
    package let title: WatchTitle
    package let why: String

    package var id: String { title.id }
}

/// The rules of What to Watch: what is sent, what may come back, and what code decides instead of the model. The
/// model only ever chooses among numbers this device sent, so a title that is not in the library cannot be picked.
package enum WatchPicker {
    package static let planAlias = "watch.plan.v1"
    package static let pickAlias = "watch.pick.v1"

    package static let usualCount = 5
    package static let mostPicks = 8
    package static let longestRequest = 300
    /// The most titles offered to the model, and the most characters of them: the service takes 60,000 a message.
    package static let candidateLimit = 900
    package static let inputBudget = 54_000
    private static let longestReason = 160
    private static let longestNote = 200

    /// Ratings that mark a title as not for children, as Plex writes them across countries ("R", "gb/18", "de/16").
    private static let adultRatings: Set<String> = ["R", "NC-17", "X", "TV-MA", "MA15+", "R18+", "M18", "18", "18+", "16", "16+", "15", "15+", "FSK 16", "FSK 18", "K-16", "K-18"]

    /// The request as it is sent: one line, without what a line of the message means, and not past the limit.
    package static func cleaned(_ request: String) -> String {
        let oneLine = request.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "|", with: " ")
        return String(oneLine.trimmingCharacters(in: .whitespaces).prefix(longestRequest))
    }

    package static func planInput(_ request: String, year: Int) -> String {
        "Year now: \(year)\nThey asked: \(cleaned(request))"
    }

    /// The plan from the service's reply, or nil when it is not one. A figure out of range is dropped, an era given
    /// backwards is turned round, and the count stays between one and the most picks.
    package static func plan(from reply: String) -> WatchPlan? {
        guard let data = reply.data(using: .utf8), let wire = try? JSONDecoder().decode(PlanWire.self, from: data) else { return nil }
        let minutes: (Int?) -> Int? = { $0.flatMap { (1...1_000).contains($0) ? $0 : nil } }
        let year: (Int?) -> Int? = { $0.flatMap { (1880...2100).contains($0) ? $0 : nil } }
        var plan = WatchPlan(
            kind: WatchTitle.Kind(rawValue: wire.kind ?? ""), watched: WatchPlan.Watched(rawValue: wire.watched ?? "") ?? .any,
            maxMinutes: minutes(wire.max_minutes), minMinutes: minutes(wire.min_minutes), fromYear: year(wire.from_year), toYear: year(wire.to_year),
            family: wire.family ?? false, count: min(mostPicks, max(1, wire.count ?? usualCount)))
        if let from = plan.fromYear, let to = plan.toYear, from > to {
            plan.fromYear = to
            plan.toYear = from
        }
        if let longest = plan.maxMinutes, let shortest = plan.minMinutes, shortest > longest { plan.minMinutes = nil }
        return plan
    }

    /// The titles that pass the plan's limits, in the order they are numbered for the model: when more pass than can
    /// be sent, the ones not yet seen come first, then the better rated, then the newer in the library. A title whose
    /// length or year is unknown passes a limit on it, so a gap in the metadata never hides a film.
    package static func candidates(for plan: WatchPlan, in titles: [WatchTitle], limit: Int = candidateLimit) -> [WatchTitle] {
        let passing = titles.filter { title in
            if let kind = plan.kind, title.kind != kind { return false }
            switch plan.watched {
            case .unseen: if title.seen != .unseen { return false }
            case .seen: if title.seen == .unseen { return false }
            case .any: break
            }
            if let longest = plan.maxMinutes, let minutes = title.minutes, minutes > longest { return false }
            if let shortest = plan.minMinutes, let minutes = title.minutes, minutes < shortest { return false }
            if let from = plan.fromYear, let year = title.year, year < from { return false }
            if let to = plan.toYear, let year = title.year, year > to { return false }
            if plan.family, isForAdults(title.contentRating) { return false }
            return true
        }
        guard passing.count > limit else { return passing }
        return Array(passing.sorted(by: comesFirst).prefix(limit))
    }

    private static func comesFirst(_ a: WatchTitle, _ b: WatchTitle) -> Bool {
        if (a.seen == .unseen) != (b.seen == .unseen) { return a.seen == .unseen }
        if (a.rating ?? 0) != (b.rating ?? 0) { return (a.rating ?? 0) > (b.rating ?? 0) }
        if a.addedAt != b.addedAt { return a.addedAt > b.addedAt }
        return a.id < b.id
    }

    package static func isForAdults(_ contentRating: String?) -> Bool {
        guard let contentRating else { return false }
        let bare = contentRating.split(separator: "/").last.map(String.init) ?? contentRating
        return adultRatings.contains(bare.trimmingCharacters(in: .whitespaces).uppercased())
    }

    /// The candidates the model is told of: as many, from the first, as fit the message's budget. Only these may be
    /// picked.
    package static func offered(_ request: String, plan: WatchPlan, candidates: [WatchTitle]) -> [WatchTitle] {
        var length = pickOpening(request, plan: plan).count
        var kept = 0
        for (place, title) in candidates.enumerated() {
            length += digestLine(title, number: place + 1).count + 1
            guard length <= inputBudget else { break }
            kept += 1
        }
        return Array(candidates.prefix(kept))
    }

    /// The message the pick alias reads: the request, the ceiling, and one numbered line per offered candidate. A
    /// candidate's number is its place in `candidates`, counted from one.
    package static func pickInput(_ request: String, plan: WatchPlan, candidates: [WatchTitle]) -> String {
        let lines = offered(request, plan: plan, candidates: candidates).enumerated().map { "\n" + digestLine($1, number: $0 + 1) }
        return pickOpening(request, plan: plan) + lines.joined()
    }

    private static func pickOpening(_ request: String, plan: WatchPlan) -> String {
        var message = "They asked: \(cleaned(request))\n"
        if plan.family { message += "Children will be watching.\n" }
        return message + "Choose up to \(plan.count).\nTitles:"
    }

    /// `number|title|year|kind|genres|minutes|rating|rated|seen`, with nothing in a field that could pose as another.
    package static func digestLine(_ title: WatchTitle, number: Int) -> String {
        let field: (String?) -> String = { ($0 ?? "").replacingOccurrences(of: "|", with: " ").components(separatedBy: .newlines).joined(separator: " ") }
        let rating = title.rating.map { String(format: "%.1f", $0) } ?? ""
        let seen = title.seen == .unseen ? "" : title.seen.rawValue
        return [
            String(number), field(String(title.title.prefix(120))), title.year.map(String.init) ?? "", title.kind.rawValue,
            field(title.genres.joined(separator: ", ")), title.minutes.map(String.init) ?? "", rating, field(title.contentRating), seen,
        ].joined(separator: "|")
    }

    /// The picks of a reply as titles, or nil when the reply is not one. `candidates` are the ones that were offered.
    /// A number that was not sent, a title chosen twice and anything past the plan's count are dropped; a reason is
    /// one line of bounded length.
    package static func picks(from reply: String, candidates: [WatchTitle], plan: WatchPlan) -> (picks: [WatchPick], note: String)? {
        guard let data = reply.data(using: .utf8), let wire = try? JSONDecoder().decode(PickWire.self, from: data) else { return nil }
        var chosen = Set<String>()
        let picks = wire.picks.compactMap { pick -> WatchPick? in
            guard pick.id >= 1, pick.id <= candidates.count else { return nil }
            let title = candidates[pick.id - 1]
            guard chosen.insert(title.id).inserted else { return nil }
            return WatchPick(title: title, why: oneLine(pick.why, limit: longestReason))
        }
        return (Array(picks.prefix(plan.count)), oneLine(wire.note ?? "", limit: longestNote))
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        String(text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(limit))
    }

    private struct PlanWire: Decodable {
        let kind: String?
        let watched: String?
        let max_minutes: Int?
        let min_minutes: Int?
        let from_year: Int?
        let to_year: Int?
        let family: Bool?
        let count: Int?
    }

    private struct PickWire: Decodable {
        struct Pick: Decodable {
            let id: Int
            let why: String
        }

        let picks: [Pick]
        let note: String?
    }
}
