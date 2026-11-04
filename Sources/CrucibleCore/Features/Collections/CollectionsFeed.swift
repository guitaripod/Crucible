import Foundation
import MidgarCore

/// Reads a library's collections and what is in them.
package enum CollectionsFeed {
    private static let pageSize = 200

    /// Every collection of a movie or show library, in the order the server lists them.
    package static func collections(inSection sectionId: String, api: APIClient) async throws -> [PlexMetadata] {
        try await allPages { start in
            try await api.requestContainer(.sectionCollections(sectionId: sectionId, start: start, size: pageSize))
        }
    }

    /// The titles inside one collection.
    package static func items(inCollection ratingKey: String, api: APIClient) async throws -> [PlexMetadata] {
        try await allPages { start in
            try await api.requestContainer(.collectionItems(ratingKey: ratingKey, start: start, size: pageSize))
        }
    }

    /// The collection called `name` in a library, which is how a title's collection tag finds its collection: the tag carries only the name.
    package static func collection(named name: String, inSection sectionId: String, api: APIClient) async throws -> PlexMetadata? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try await collections(inSection: sectionId, api: api).first {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
        }
    }

    private static func allPages(_ load: (Int) async throws -> PlexMediaContainer) async throws -> [PlexMetadata] {
        var all: [PlexMetadata] = []
        var start = 0
        while true {
            let container = try await load(start)
            try Task.checkCancellation()
            let page = container.Metadata ?? []
            all.append(contentsOf: page)
            start += page.count
            let total = container.totalSize ?? container.size ?? start
            guard !page.isEmpty, start < total else { return all }
        }
    }
}

/// What a collection says about itself on its card.
package enum CollectionFormat {
    /// "12 titles" for a collection with a known size, nil when the server did not say.
    package static func countText(_ collection: PlexMetadata) -> String? {
        guard let count = collection.childCount, count > 0 else { return nil }
        return count == 1 ? String(localized: "1 title") : String(localized: "\(count) titles")
    }
}
