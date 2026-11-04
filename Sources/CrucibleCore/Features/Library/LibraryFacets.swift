import Foundation

/// A way to narrow a library besides its genre: the server lists the values a library holds for each, and the listing filters by one of
/// them.
package enum LibraryFacet: String, CaseIterable, Sendable {
    case decade
    case contentRating
    case resolution

    /// The server's name for the listing of values and for the filter that takes one.
    package var queryName: String { rawValue }

    package var title: String {
        switch self {
        case .decade: return String(localized: "Decade", comment: "Library filter: the decade a title came out in")
        case .contentRating: return String(localized: "Rated", comment: "Library filter: the age rating of a title, such as PG-13")
        case .resolution: return String(localized: "Resolution", comment: "Library filter: the picture size of a title, such as 4K")
        }
    }

    package var allTitle: String {
        switch self {
        case .decade: return String(localized: "All Decades", comment: "Library filter choice that removes the decade filter")
        case .contentRating: return String(localized: "All Ratings", comment: "Library filter choice that removes the age rating filter")
        case .resolution: return String(localized: "All Resolutions", comment: "Library filter choice that removes the resolution filter")
        }
    }

    package var symbol: String {
        switch self {
        case .decade: return "calendar"
        case .contentRating: return "person.badge.shield.checkmark"
        case .resolution: return "tv.badge.wifi"
        }
    }

    /// How a value the server lists reads in a menu: resolutions are spelled the way the badges spell them.
    package func display(_ title: String) -> String {
        guard self == .resolution else { return title }
        switch title.lowercased() {
        case "4k": return "4K"
        case "sd": return "SD"
        default: return Int(title).map { "\($0)p" } ?? title
        }
    }
}

package struct LibraryFacetChoice: Equatable, Sendable {
    package let key: String
    package let title: String

    package init(key: String, title: String) {
        self.key = key
        self.title = title
    }
}
