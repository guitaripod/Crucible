import Foundation

package enum HistoryFilter: String, CaseIterable, Sendable {
    case all, movies, tv

    package var title: String {
        switch self {
        case .all: return String(localized: "All", comment: "Filter option that shows every item")
        case .movies: return String(localized: "Movies", comment: "Media type: films, as a plural")
        case .tv: return String(localized: "TV", comment: "Media type: television")
        }
    }

    package func includes(_ item: HistoryItem) -> Bool {
        switch self {
        case .all: return true
        case .movies: return item.type == "movie"
        case .tv: return item.type == "episode" || item.type == "show" || item.type == "season"
        }
    }
}
