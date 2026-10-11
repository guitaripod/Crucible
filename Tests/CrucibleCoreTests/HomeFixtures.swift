import Foundation
@testable import CrucibleCore

enum HomeFixtures {
    typealias JSON = [String: Any]

    static func raw(_ key: String, type: String = "movie", title: String? = nil, fields: JSON = [:]) -> JSON {
        var json: JSON = ["ratingKey": key, "type": type, "title": title ?? "Title \(key)"]
        json.merge(fields) { _, new in new }
        return json
    }

    static func item(_ key: String, type: String = "movie", title: String? = nil, fields: JSON = [:]) -> PlexMetadata {
        decode(PlexMetadata.self, raw(key, type: type, title: title, fields: fields))
    }

    static func hub(_ identifier: String?, _ items: [JSON]?) -> JSON {
        var json: JSON = [:]
        if let identifier { json["hubIdentifier"] = identifier }
        if let items { json["Metadata"] = items }
        return json
    }

    static func hubs(_ hubs: [JSON]) -> [PlexHub] {
        hubs.map { decode(PlexHub.self, $0) }
    }

    static func hubsContainer(_ hubs: [JSON]) -> PlexMediaContainer {
        decode(PlexMediaContainer.self, ["Hub": hubs])
    }

    static func metadataContainer(_ items: [JSON]) -> PlexMediaContainer {
        decode(PlexMediaContainer.self, ["Metadata": items])
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: Any) -> T {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(T.self, from: data)
    }
}
