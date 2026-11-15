import Foundation

/// Where Sports Research stands on the paired Crucible Server: every requirement, the owner's settings, what the
/// server is doing and what it did, as `GET /sports` reports it.
package struct SportsReport: Decodable, Equatable, Sendable {
    package var owner: Bool
    package var ready: Bool
    package var checks: [SportsCheck]
    package var settings: SportsSettings
    package var libraries: [SportsLibrary]
    package var status: SportsStatus
    package var counts: [String: Int]
    package var items: [SportsItem]

    package init(owner: Bool, ready: Bool, checks: [SportsCheck], settings: SportsSettings, libraries: [SportsLibrary], status: SportsStatus, counts: [String: Int], items: [SportsItem]) {
        self.owner = owner
        self.ready = ready
        self.checks = checks
        self.settings = settings
        self.libraries = libraries
        self.status = status
        self.counts = counts
        self.items = items
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

package struct SportsStatus: Decodable, Equatable, Sendable {
    /// The file being researched and the step the model is on.
    package struct Current: Decodable, Equatable, Sendable {
        package var ratingKey: String
        package var name: String
        package var step: String
        package var started: Int

        package init(ratingKey: String, name: String, step: String, started: Int) {
            self.ratingKey = ratingKey
            self.name = name
            self.step = step
            self.started = started
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

/// The command a fix names for the computer with Plex, such as `crucible-server sports --on`, when it names one.
package func sportsCommand(in fix: String) -> String? {
    guard let start = fix.range(of: "crucible-server ") else { return nil }
    return String(fix[start.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// What research made of one file.
package struct SportsItem: Decodable, Equatable, Hashable, Sendable {
    package var ratingKey: String
    package var file: String
    package var state: String
    package var title: String
    package var note: String
    package var updated: Int

    package init(ratingKey: String, file: String, state: String, title: String, note: String = "", updated: Int) {
        self.ratingKey = ratingKey
        self.file = file
        self.state = state
        self.title = title
        self.note = note
        self.updated = updated
    }

    /// The file's own name, for an item research has not titled.
    package var fileName: String { file.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? file }
}

/// Every requirement, in the order a person meets them and grouped the way the screen shows them.
package enum SportsRequirement: String, CaseIterable, Sendable {
    case owner
    case model
    case tools
    case thinking
    case context
    case search
    case agreement
    case libraries
    case on

    package enum Group: Int, CaseIterable, Sendable {
        case plex
        case model
        case web
        case library
    }

    package var group: Group {
        switch self {
        case .owner: .plex
        case .model, .tools, .thinking, .context: .model
        case .search, .agreement: .web
        case .libraries, .on: .library
        }
    }

    /// Whether the owner settles it from the app rather than on the server.
    package var settledInApp: Bool {
        self == .agreement || self == .libraries || self == .on
    }
}

extension SportsCheck {
    /// Whether this unmet requirement is the owner's to settle with the app's own controls: one of the choices, or one that
    /// waits on them (search is tried only once the owner agrees).
    package func settledInApp(byOwner owner: Bool) -> Bool {
        owner && state != .done && (requirement?.settledInApp == true || fix?.contains("in Crucible") == true)
    }
}

/// The report arranged for the screen: requirements by group, how far setup is, and one line about what the server
/// is doing.
package struct SportsBoard: Equatable, Sendable {
    package let report: SportsReport

    package init(report: SportsReport) {
        self.report = report
    }

    /// The checks of each group in requirement order, skipping groups the server reported nothing for.
    package var groups: [(SportsRequirement.Group, [SportsCheck])] {
        let known = report.checks.filter { $0.requirement != nil }.sorted {
            (SportsRequirement.allCases.firstIndex(of: $0.requirement!) ?? 0) < (SportsRequirement.allCases.firstIndex(of: $1.requirement!) ?? 0)
        }
        return SportsRequirement.Group.allCases.compactMap { group in
            let checks = known.filter { $0.requirement?.group == group }
            return checks.isEmpty ? nil : (group, checks)
        }
    }

    package static func == (lhs: SportsBoard, rhs: SportsBoard) -> Bool { lhs.report == rhs.report }

    package var doneCount: Int { report.checks.filter { $0.state == .done }.count }
    package var total: Int { report.checks.count }

    /// The requirements still open, in order.
    package var open: [SportsCheck] {
        groups.flatMap(\.1).filter { $0.state != .done }
    }

    /// The only thing between the owner and research is the switch.
    package var onlySwitchIsOff: Bool {
        open.map(\.id) == [SportsRequirement.on.rawValue]
    }

    package func count(_ state: String) -> Int { report.counts[state] ?? 0 }

    /// The items to list, the ones needing a look first, then by newest change.
    package var items: [SportsItem] {
        let weight: (String) -> Int = { state in
            switch state {
            case "attention": 0
            case "failed": 1
            default: 2
            }
        }
        return report.items.sorted { weight($0.state) != weight($1.state) ? weight($0.state) < weight($1.state) : $0.updated > $1.updated }
    }
}

/// Where a Sports Research screen gets its report and sends the owner's changes: the paired Crucible Server, or a fixture
/// in screenshots and UI tests.
package protocol SportsSource: Sendable {
    func sports() async throws(CompanionError) -> SportsReport
    /// Whether the server has Sports Research at all; a server from before it answers its routes with nothing useful.
    func hasSports() async -> Bool
    func changeSports(on: Bool?, libraries: [String]?, agree: Bool?) async throws(CompanionError)
    func recheckSports() async throws(CompanionError)
    func runSports() async throws(CompanionError)
    func redoSports(ratingKey: String) async throws(CompanionError)
}

extension CompanionClient: SportsSource {
    package func hasSports() async -> Bool {
        (try? await hello())?.sports == true
    }
}

/// A report read from a JSON file in the shape `GET /sports` answers, whose changes go nowhere.
package struct SportsFixture: SportsSource {
    private let url: URL

    package init(url: URL) {
        self.url = url
    }

    package func sports() async throws(CompanionError) -> SportsReport {
        guard let data = try? Data(contentsOf: url), let report = try? JSONDecoder().decode(SportsReport.self, from: data) else {
            throw .failed("No Sports Research fixture at \(url.path)")
        }
        return report
    }

    package func hasSports() async -> Bool { true }
    package func changeSports(on: Bool?, libraries: [String]?, agree: Bool?) async throws(CompanionError) {}
    package func recheckSports() async throws(CompanionError) {}
    package func runSports() async throws(CompanionError) {}
    package func redoSports(ratingKey: String) async throws(CompanionError) {}
}

/// How a researched file is named in lists.
package enum SportsItemLabel {
    /// The title research gave it when it has one (matched, or edited by the owner since), else the file's own name.
    package static func title(_ item: SportsItem) -> String {
        switch item.state {
        case "matched", "edited" where !item.title.isEmpty: item.title
        default: item.fileName
        }
    }
}
