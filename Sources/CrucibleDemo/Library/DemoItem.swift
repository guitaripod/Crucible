import Foundation

typealias DemoJSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int? {
        (self[key] as? NSNumber)?.intValue
    }

    func string(_ key: String) -> String? {
        self[key] as? String
    }

    func double(_ key: String) -> Double? {
        (self[key] as? NSNumber)?.doubleValue
    }
}

struct DemoMediaFacts {
    let width: Int
    let height: Int
    let hdr: Bool
    let size: Int
}

/// One title of the catalogue (a movie, a show, a season or an episode) together with its mutable Plex fields.
struct DemoItem {
    enum Kind: String {
        case movie, show, season, episode
    }

    let kind: Kind
    var fields: DemoJSON
    let genres: [String]
    let directors: [String]
    let writers: [String]
    let cast: [DemoJSON]
    let related: [String]
    let media: DemoMediaFacts?
    let show: String?
    let season: String?
    var children: [String] = []

    mutating func set(_ key: String, _ value: Int?) {
        if let value {
            fields[key] = value
        } else {
            fields[key] = nil
        }
    }

    var ratingKey: String { fields.string("ratingKey") ?? "" }
    var title: String { fields.string("title") ?? "" }
    var titleSort: String { fields.string("titleSort") ?? title.lowercased() }
    var sectionID: Int { fields.int("librarySectionID") ?? 0 }
    var durationMs: Int { fields.int("duration") ?? 0 }
    var viewCount: Int { fields.int("viewCount") ?? 0 }
    var viewOffset: Int { fields.int("viewOffset") ?? 0 }
    var lastViewedAt: Int { fields.int("lastViewedAt") ?? 0 }
    var addedAt: Int { fields.int("addedAt") ?? 0 }
    var isWatched: Bool { viewCount > 0 }
    var isPlayable: Bool { kind == .movie || kind == .episode }
    var isInProgress: Bool { viewOffset > 0 && !isWatched }
}

struct DemoSection {
    let id: String
    let title: String
    let type: String
}

struct DemoHistoryRow {
    let id: Int
    let ratingKey: String
    let viewedAt: Int
}

/// What the library has to remember between launches: the watch state of every title the viewer changed, and the plays they added.
struct DemoPersistedState: Codable {
    struct ItemState: Codable {
        var viewCount: Int
        var viewOffset: Int
        var lastViewedAt: Int
    }

    struct Play: Codable {
        var ratingKey: String
        var viewedAt: Int
    }

    var version = 1
    var items: [String: ItemState] = [:]
    var plays: [Play] = []
    var onDeck: [String]?
}
