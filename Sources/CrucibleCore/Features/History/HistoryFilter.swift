import Foundation

package enum HistoryFilter: String, CaseIterable, Sendable {
    case all, movies, tv

    package var title: String {
        switch self {
        case .all: return "All"
        case .movies: return "Movies"
        case .tv: return "TV"
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
