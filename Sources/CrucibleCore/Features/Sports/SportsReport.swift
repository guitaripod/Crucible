import Foundation

/// Where Sports Research stands on the paired Crucible Server: every requirement, the owner's settings, what the
/// server is doing and what it made of each file, as `GET /sports` reports it. Fields a server from before v2 does not
/// send decode as empty.
package struct SportsReport: Decodable, Equatable, Sendable {
    package var owner: Bool
    package var ready: Bool
    package var checks: [SportsCheck]
    package var settings: SportsSettings
    package var libraries: [SportsLibrary]
    package var status: SportsStatus
    package var counts: [String: Int]
    package var items: [SportsItem]
    package var model: SportsModel?

    package init(owner: Bool, ready: Bool, checks: [SportsCheck], settings: SportsSettings, libraries: [SportsLibrary], status: SportsStatus, counts: [String: Int], items: [SportsItem], model: SportsModel? = nil) {
        self.owner = owner
        self.ready = ready
        self.checks = checks
        self.settings = settings
        self.libraries = libraries
        self.status = status
        self.counts = counts
        self.items = items
        self.model = model
    }
}

/// The model doing the research, by name and the host it runs on.
package struct SportsModel: Decodable, Equatable, Sendable {
    package var name: String
    package var host: String

    package init(name: String, host: String) {
        self.name = name
        self.host = host
    }
}

/// One requirement and where it stands. A state this version does not know reads as failed.
package struct SportsCheck: Decodable, Equatable, Hashable, Sendable {
    package enum State: String, Sendable {
        case done
        case missing
        case failed
    }

    package var id: String
    package var state: State
    package var detail: String
    package var fix: String?

    package init(id: String, state: State, detail: String, fix: String? = nil) {
        self.id = id
        self.state = state
        self.detail = detail
        self.fix = fix
    }

    enum CodingKeys: String, CodingKey { case id, state, detail, fix }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        state = State(rawValue: try container.decode(String.self, forKey: .state)) ?? .failed
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        fix = try container.decodeIfPresent(String.self, forKey: .fix)
    }

    package var requirement: SportsRequirement? { SportsRequirement(rawValue: id) }
}

package struct SportsSettings: Decodable, Equatable, Sendable {
    package var on: Bool
    package var engine: String?
    package var destination: String?
    package var agreed: Bool

    package init(on: Bool, engine: String? = nil, destination: String? = nil, agreed: Bool) {
        self.on = on
        self.engine = engine
        self.destination = destination
        self.agreed = agreed
    }
}

/// An Other Videos library on the Plex server and whether research reads it.
package struct SportsLibrary: Decodable, Equatable, Hashable, Sendable {
    package var key: String
    package var title: String
    package var chosen: Bool

    package init(key: String, title: String, chosen: Bool) {
        self.key = key
        self.title = title
        self.chosen = chosen
    }
}

/// One step of a live research, as the server's timeline records it.
package struct SportsLiveStep: Decodable, Equatable, Hashable, Sendable {
    package enum Kind: String, Sendable {
        case thinking
        case searching
        case reading
        case checking
        case writing
    }

    package var id: Int
    package var kind: Kind
    package var detail: String
    package var at: Int

    package init(id: Int, kind: Kind, detail: String = "", at: Int) {
        self.id = id
        self.kind = kind
        self.detail = detail
        self.at = at
    }

    enum CodingKeys: String, CodingKey { case id, kind, detail, at }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        kind = Kind(rawValue: try container.decodeIfPresent(String.self, forKey: .kind) ?? "") ?? .thinking
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        at = try container.decodeIfPresent(Int.self, forKey: .at) ?? 0
    }
}

package struct SportsStatus: Decodable, Equatable, Sendable {
    /// The file being researched and the steps the model has taken on it.
    package struct Current: Decodable, Equatable, Sendable {
        package var ratingKey: String
        package var name: String
        package var file: String
        package var step: String
        package var started: Int
        package var elapsed: Int
        package var steps: [SportsLiveStep]

        package init(ratingKey: String, name: String, file: String = "", step: String = "", started: Int, elapsed: Int = 0, steps: [SportsLiveStep] = []) {
            self.ratingKey = ratingKey
            self.name = name
            self.file = file
            self.step = step
            self.started = started
            self.elapsed = elapsed
            self.steps = steps
        }

        enum CodingKeys: String, CodingKey { case ratingKey, name, file, step, started, elapsed, steps }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ratingKey = try container.decode(String.self, forKey: .ratingKey)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            file = try container.decodeIfPresent(String.self, forKey: .file) ?? ""
            step = try container.decodeIfPresent(String.self, forKey: .step) ?? ""
            started = try container.decodeIfPresent(Int.self, forKey: .started) ?? 0
            elapsed = try container.decodeIfPresent(Int.self, forKey: .elapsed) ?? 0
            steps = try container.decodeIfPresent([SportsLiveStep].self, forKey: .steps) ?? []
        }

        /// The newest steps first, as the timeline shows them.
        package func newestSteps(_ count: Int) -> [SportsLiveStep] {
            Array(steps.suffix(count).reversed())
        }
    }

    package var phase: String
    package var current: Current?
    package var queued: Int
    package var lastPass: Int?
    package var lastError: String?

    package init(phase: String, current: Current? = nil, queued: Int = 0, lastPass: Int? = nil, lastError: String? = nil) {
        self.phase = phase
        self.current = current
        self.queued = queued
        self.lastPass = lastPass
        self.lastError = lastError
    }

    package var isWorking: Bool { phase == "looking" || phase == "researching" || phase == "writing" }
}

/// The event research found for a file.
package struct SportsEventDetail: Decodable, Equatable, Hashable, Sendable {
    package struct Bout: Decodable, Equatable, Hashable, Sendable {
        package var matchup: String
        package var detail: String

        package init(matchup: String, detail: String = "") {
            self.matchup = matchup
            self.detail = detail
        }
    }

    package var event: String
    package var part: String?
    package var date: String
    package var venue: String
    package var city: String
    package var headline: String
    package var league: String
    package var sport: String
    package var summary: String
    package var lineup: [Bout]
    package var sources: [String]
    package var posterUrl: String?

    package init(event: String, part: String? = nil, date: String = "", venue: String = "", city: String = "", headline: String = "", league: String = "", sport: String = "", summary: String = "", lineup: [Bout] = [], sources: [String] = [], posterUrl: String? = nil) {
        self.event = event
        self.part = part
        self.date = date
        self.venue = venue
        self.city = city
        self.headline = headline
        self.league = league
        self.sport = sport
        self.summary = summary
        self.lineup = lineup
        self.sources = sources
        self.posterUrl = posterUrl
    }

    enum CodingKeys: String, CodingKey { case event, part, date, venue, city, headline, league, sport, summary, lineup, sources, posterUrl }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decodeIfPresent(String.self, forKey: .event) ?? ""
        part = try container.decodeIfPresent(String.self, forKey: .part)
        date = try container.decodeIfPresent(String.self, forKey: .date) ?? ""
        venue = try container.decodeIfPresent(String.self, forKey: .venue) ?? ""
        city = try container.decodeIfPresent(String.self, forKey: .city) ?? ""
        headline = try container.decodeIfPresent(String.self, forKey: .headline) ?? ""
        league = try container.decodeIfPresent(String.self, forKey: .league) ?? ""
        sport = try container.decodeIfPresent(String.self, forKey: .sport) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        lineup = try container.decodeIfPresent([Bout].self, forKey: .lineup) ?? []
        sources = try container.decodeIfPresent([String].self, forKey: .sources) ?? []
        posterUrl = try container.decodeIfPresent(String.self, forKey: .posterUrl)
    }

    /// The event's day, from the `YYYY-MM-DD` the server sends.
    package var day: Date? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// Venue and city as one place, without repeating a city the venue already names.
    package var place: String {
        let venue = venue.trimmingCharacters(in: .whitespaces)
        let city = city.trimmingCharacters(in: .whitespaces)
        if city.isEmpty || venue.contains(city) { return venue }
        if venue.isEmpty { return city }
        return "\(venue), \(city)"
    }
}

/// What research made of one file.
package struct SportsItem: Decodable, Equatable, Hashable, Sendable {
    package var ratingKey: String
    package var file: String
    package var state: String
    package var title: String
    package var note: String
    package var updated: Int
    package var seconds: Int
    package var searches: Int
    package var reads: Int
    /// Whether the server counted what the research took; files researched before it did come without the counts.
    package var measured: Bool
    package var detail: SportsEventDetail?

    package init(ratingKey: String, file: String, state: String, title: String, note: String = "", updated: Int, seconds: Int = 0, searches: Int = 0, reads: Int = 0, measured: Bool = true, detail: SportsEventDetail? = nil) {
        self.ratingKey = ratingKey
        self.file = file
        self.state = state
        self.title = title
        self.note = note
        self.updated = updated
        self.seconds = seconds
        self.searches = searches
        self.reads = reads
        self.measured = measured
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey { case ratingKey, file, state, title, note, updated, seconds, searches, reads, detail }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        file = try container.decodeIfPresent(String.self, forKey: .file) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "failed"
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        updated = try container.decodeIfPresent(Int.self, forKey: .updated) ?? 0
        let effort = [
            try container.decodeIfPresent(Int.self, forKey: .seconds),
            try container.decodeIfPresent(Int.self, forKey: .searches),
            try container.decodeIfPresent(Int.self, forKey: .reads),
        ]
        measured = effort.allSatisfy { ($0 ?? -1) >= 0 }
        seconds = max(0, effort[0] ?? 0)
        searches = max(0, effort[1] ?? 0)
        reads = max(0, effort[2] ?? 0)
        detail = try container.decodeIfPresent(SportsEventDetail.self, forKey: .detail)
    }

    /// The file's own name, for an item research has not titled.
    package var fileName: String { file.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? file }

    /// Whether the research of another part of the same event was reused, so this file took no research of its own.
    package var reusedResearch: Bool { measured && state == "matched" && seconds == 0 && searches == 0 && reads == 0 }

    /// The Plex path of the poster Plex shows for it, which research replaces with the event's artwork.
    package var posterPath: String { "/library/metadata/\(ratingKey)/thumb" }

    /// The words a drawn poster carries until Plex's own arrives: the event's number with the part, and the main bout.
    package var posterWords: SportsPosterWords? {
        guard let detail, state == "matched" || state == "edited" else { return nil }
        return SportsPosterWords(event: detail.event, part: detail.part, headline: detail.headline)
    }
}

/// The two lines of a drawn poster: "UFC 334 · PRELIMS" above "Gane vs. Hokit".
package struct SportsPosterWords: Equatable, Hashable, Sendable {
    package var eyebrow: String
    package var caption: String

    package init(eyebrow: String, caption: String) {
        self.eyebrow = eyebrow
        self.caption = caption
    }

    /// From an event title such as "UFC 334: Gane vs. Hokit", its part and its headline.
    package init(event: String, part: String?, headline: String) {
        let pieces = event.components(separatedBy: ": ")
        let number = pieces.count > 1 ? pieces[0] : event
        let named = pieces.count > 1 ? pieces.dropFirst().joined(separator: ": ") : ""
        let shownPart = part.flatMap { $0 == "Main card" || $0 == "Full event" ? nil : $0 }
        eyebrow = [number, shownPart].compactMap { $0 }.joined(separator: " · ")
        caption = headline.isEmpty ? named : headline
    }
}

extension SportsReport {
    /// The report as it will read once the owner's change lands, shown while the server takes it.
    package func expecting(on: Bool? = nil, libraries: [String]? = nil, agree: Bool? = nil) -> SportsReport {
        var report = self
        if let on { report.settings.on = on }
        if let libraries {
            report.libraries = report.libraries.map { SportsLibrary(key: $0.key, title: $0.title, chosen: libraries.contains($0.key)) }
        }
        if let agree { report.settings.agreed = agree }
        return report
    }
}

/// The command a fix names for the computer with Plex, such as `crucible-server sports --on`, when it names one: the
/// command alone, without the words or the alternative that may follow it.
package func sportsCommand(in fix: String) -> String? {
    guard let start = fix.range(of: "crucible-server ") else { return nil }
    var command = Substring(fix[start.lowerBound...])
    for ending in [" (", ", or ", "; ", ". "] {
        if let found = command.range(of: ending) {
            command = command[..<found.lowerBound]
        }
    }
    return command.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
}
