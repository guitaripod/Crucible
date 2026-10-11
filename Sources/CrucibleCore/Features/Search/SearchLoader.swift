import Foundation

package struct SearchLoader: Sendable {
    package typealias Fetch = @Sendable (PlexEndpoint) async throws -> PlexMediaContainer

    package static let maxGenres = 8
    private static let pageSize = 100
    private static let maxItemsPerSource = 2000

    private let fetch: Fetch

    package init(api: APIClient) {
        fetch = { try await api.requestContainer($0) }
    }

    package init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    package func search(query: String) async throws -> SearchResults {
        let container = try await fetch(.search(query: query))
        return SearchResults(hubs: container.Hub ?? [])
    }

    package func genres() async -> [SearchGenre] {
        guard let sections = try? await fetch(.sections) else { return [] }
        let sectionIds = (sections.Directory ?? [])
            .filter { $0.type == "movie" || $0.type == "show" }
            .compactMap(\.key)

        var order = [String]()
        var titles = [String: String]()
        var sources = [String: [GenreSource]]()
        for sectionId in sectionIds {
            guard let container = try? await fetch(.sectionGenres(sectionId: sectionId)) else { continue }
            for directory in container.Directory ?? [] {
                guard let key = directory.key, let title = directory.title else { continue }
                let merged = title.lowercased()
                if titles[merged] == nil {
                    titles[merged] = title
                    order.append(merged)
                }
                sources[merged, default: []].append(GenreSource(sectionId: sectionId, key: key))
            }
        }
        return order.prefix(Self.maxGenres).compactMap { merged in
            guard let title = titles[merged], let genreSources = sources[merged] else { return nil }
            return SearchGenre(title: title, sources: genreSources)
        }
    }

    package func recentlyAdded() async -> [PlexMetadata] {
        guard let container = try? await fetch(.recentlyAdded(start: 0, size: 30)) else { return [] }
        var seen = Set<String>()
        return (container.Metadata ?? []).filter {
            ["movie", "show", "season", "episode"].contains($0.mediaType) && seen.insert($0.id).inserted
        }
    }

    /// Every title tagged with the genre across all of its library sections, de-duplicated and sorted by title.
    package func items(genre: SearchGenre) async throws -> [PlexMetadata] {
        let batches = try await withThrowingTaskGroup(of: [PlexMetadata].self) { group in
            for source in genre.sources {
                group.addTask { try await allItems(source: source) }
            }
            var collected = [[PlexMetadata]]()
            for try await batch in group { collected.append(batch) }
            return collected
        }
        var seen = Set<String>()
        return batches.flatMap { $0 }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func allItems(source: GenreSource) async throws -> [PlexMetadata] {
        var collected = [PlexMetadata]()
        var start = 0
        while start < Self.maxItemsPerSource {
            try Task.checkCancellation()
            let container = try await fetch(
                .sectionItems(sectionId: source.sectionId, sort: "titleSort:asc", genre: source.key, start: start, size: Self.pageSize)
            )
            let page = container.Metadata ?? []
            collected.append(contentsOf: page)
            let total = container.totalSize ?? 0
            start += Self.pageSize
            if page.count < Self.pageSize || (total > 0 && start >= total) { break }
        }
        return collected
    }
}
