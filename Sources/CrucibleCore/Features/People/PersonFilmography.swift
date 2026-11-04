import Foundation
import MidgarCore

/// What a cast member has done in the viewer's libraries: every movie and show of every library whose cast lists them, newest first.
package enum PersonFilmography {
    private static let pageSize = 200

    /// Whether the server gave the person an id to look them up by; crew rows built from names alone have none.
    package static func canOpen(_ person: PlexRole) -> Bool {
        person.id != nil
    }

    package static func titles(of person: PlexRole, api: APIClient) async throws -> [PlexMetadata] {
        guard let id = person.id else { return [] }
        let sections = (try await api.requestContainer(.sections).Directory ?? []).filter { ["movie", "show"].contains($0.type) }
        var found: [PlexMetadata] = []
        for section in sections {
            guard let key = section.key else { continue }
            found += try await pages(sectionId: key, actor: String(id), api: api)
        }
        var seen = Set<String>()
        return found
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.year ?? 0, $1.title.lowercased()) > ($1.year ?? 0, $0.title.lowercased()) }
    }

    private static func pages(sectionId: String, actor: String, api: APIClient) async throws -> [PlexMetadata] {
        var all: [PlexMetadata] = []
        var start = 0
        while true {
            let container = try await api.requestContainer(.sectionItems(sectionId: sectionId, start: start, size: pageSize, actor: actor))
            try Task.checkCancellation()
            let page = container.Metadata ?? []
            all.append(contentsOf: page)
            start += page.count
            let total = container.totalSize ?? container.size ?? start
            guard !page.isEmpty, start < total else { return all }
        }
    }
}
