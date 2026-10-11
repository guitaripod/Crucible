import Foundation

/// Picks a random title from the recently added pool for the Surprise Me action.
package enum SurpriseMe {
    package enum Kind: Hashable, Sendable {
        case any
        case movie
        case show

        package var menuTitle: String {
            switch self {
            case .any: return "Any"
            case .movie: return "Movie"
            case .show: return "Show"
            }
        }

        fileprivate var noun: String {
            switch self {
            case .any: return "titles"
            case .movie: return "movies"
            case .show: return "shows"
            }
        }
    }

    package enum Target: Hashable, Sendable {
        case movie(String)
        case show(String)
    }

    /// The fresh lookup failed and nothing on screen could stand in for it.
    package struct LookupFailure: Error {
        package let message: String

        package init(message: String) {
            self.message = message
        }
    }

    package static let recentlyAddedPoolSize = 100

    /// What a pool item resolves to for a kind: movies and shows themselves, seasons and episodes
    /// as their show, nothing for other types or kinds that exclude it.
    package static func target(for item: PlexMetadata, kind: Kind) -> Target? {
        switch item.mediaType {
        case "movie":
            return kind == .show ? nil : .movie(item.id)
        case "show":
            return kind == .movie ? nil : .show(item.id)
        case "season":
            guard kind != .movie, let key = item.parentRatingKey else { return nil }
            return .show(key)
        case "episode":
            guard kind != .movie, let key = item.grandparentRatingKey else { return nil }
            return .show(key)
        default:
            return nil
        }
    }

    package static func pick(from pool: [PlexMetadata], kind: Kind) -> Target? {
        var generator = SystemRandomNumberGenerator()
        return pick(from: pool, kind: kind, using: &generator)
    }

    package static func pick<Generator: RandomNumberGenerator>(
        from pool: [PlexMetadata],
        kind: Kind,
        using generator: inout Generator
    ) -> Target? {
        Set(pool.compactMap { target(for: $0, kind: kind) }).randomElement(using: &generator)
    }

    package static let nothingToPickTitle = "Nothing to Pick"
    package static let lookupFailedTitle = "Couldn't Pick Something"

    package static func nothingToPickMessage(for kind: Kind) -> String {
        "There are no recently added \(kind.noun) to choose from."
    }
}
