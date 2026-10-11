import Foundation

package struct SearchRecents: Equatable, Sendable {
    package static let capacity = 8

    package private(set) var queries: [String]

    package init(_ queries: [String] = []) {
        self.queries = Array(queries.prefix(Self.capacity))
    }

    /// Puts a query at the front, replacing any entry that differs only by case. Queries shorter than the search minimum are ignored.
    package mutating func remember(_ query: String) {
        guard SearchQuery.isSearchable(query) else { return }
        queries.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        queries.insert(query, at: 0)
        queries = Array(queries.prefix(Self.capacity))
    }

    package mutating func remove(_ query: String) {
        queries.removeAll { $0 == query }
    }

    package mutating func clear() {
        queries = []
    }
}

package struct SearchRecentsStore: Sendable {
    package let load: @Sendable () -> [String]
    package let save: @Sendable ([String]) -> Void

    package init(load: @escaping @Sendable () -> [String], save: @escaping @Sendable ([String]) -> Void) {
        self.load = load
        self.save = save
    }

    /// The history the app keeps in `Preferences.recentSearches`.
    package static let preferences = SearchRecentsStore(
        load: { Preferences.recentSearches },
        save: { Preferences.recentSearches = $0 }
    )

    package var recents: SearchRecents {
        SearchRecents(load())
    }

    package func update(_ change: (inout SearchRecents) -> Void) {
        var recents = recents
        change(&recents)
        save(recents.queries)
    }
}
