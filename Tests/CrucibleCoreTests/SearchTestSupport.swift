import Foundation
import os
@testable import CrucibleCore

enum SearchFixtures {
    static let haloMovie = try! item("1", "movie", "Halo Movie")
    static let haloShow = try! item("2", "show", "Halo Show")
    static let haloEpisode = try! item("3", "episode", "Halo Episode")
    static let allHits = try! searchContainer([[haloMovie, haloShow, haloEpisode]])
    static let noHits = try! searchContainer([])

    static func item(
        _ id: String,
        _ type: String,
        _ title: String,
        _ extra: [String: Any] = [:]
    ) throws -> PlexMetadata {
        var json: [String: Any] = ["ratingKey": id, "type": type, "title": title]
        json.merge(extra) { _, new in new }
        return try JSONDecoder().decode(PlexMetadata.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func container(_ json: [String: Any]) throws -> PlexMediaContainer {
        try JSONDecoder().decode(PlexMediaContainer.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func searchContainer(_ groups: [[PlexMetadata]]) throws -> PlexMediaContainer {
        let hubs = groups.map { group in
            ["Metadata": group.map { item -> [String: Any] in
                var json: [String: Any] = ["type": item.type ?? "", "title": item.title]
                if let key = item.ratingKey { json["ratingKey"] = key }
                return json
            }]
        }
        return try container(["Hub": hubs])
    }

    static func directories(_ entries: [(key: String, title: String, type: String?)]) throws -> PlexMediaContainer {
        try container([
            "Directory": entries.map { entry -> [String: Any] in
                var json: [String: Any] = ["key": entry.key, "title": entry.title]
                if let type = entry.type { json["type"] = type }
                return json
            }
        ])
    }

    static func page(_ items: [PlexMetadata], total: Int? = nil) throws -> PlexMediaContainer {
        var json: [String: Any] = [
            "Metadata": items.map { ["ratingKey": $0.ratingKey ?? "", "type": $0.type ?? "", "title": $0.title] }
        ]
        if let total { json["totalSize"] = total }
        return try container(json)
    }
}

actor RequestLog {
    private(set) var endpoints: [PlexEndpoint] = []

    func record(_ endpoint: PlexEndpoint) {
        endpoints.append(endpoint)
    }

    var searchQueries: [String] {
        endpoints.compactMap {
            if case .search(let query) = $0 { return query }
            return nil
        }
    }

    var sectionItemStarts: [Int] {
        endpoints.compactMap {
            if case .sectionItems(_, _, _, let start, _, _, _) = $0 { return start }
            return nil
        }
    }

    var count: Int { endpoints.count }
}

actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var hasWaiter = false

    func wait() async {
        if isOpen { return }
        hasWaiter = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

final class MemoryRecents: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[String]>(initialState: [])

    init(_ initial: [String] = []) {
        lock.withLock { $0 = initial }
    }

    var queries: [String] { lock.withLock { $0 } }

    var store: SearchRecentsStore {
        SearchRecentsStore(load: { self.queries }, save: { values in self.lock.withLock { $0 = values } })
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
