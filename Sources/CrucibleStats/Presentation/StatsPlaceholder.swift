import Foundation

/// What a statistics screen shows when it has no page to draw, with the copy shared by every platform.
package enum StatsPlaceholder: Equatable, Sendable {
    case unavailable
    case loading
    case empty(filtered: Bool)

    /// The state for a store that produced an empty page: loading until the first sync finished, then
    /// empty (filtered when the user switched libraries off).
    package static func forEmptyPage(syncedAtLeastOnce: Bool, librariesFiltered: Bool) -> StatsPlaceholder {
        syncedAtLeastOnce ? .empty(filtered: librariesFiltered) : .loading
    }

    package var symbol: String? {
        switch self {
        case .unavailable: return "exclamationmark.triangle"
        case .loading: return nil
        case .empty: return "chart.bar.xaxis"
        }
    }

    package var title: String {
        switch self {
        case .unavailable: return "Statistics unavailable"
        case .loading: return "Building your statistics"
        case .empty(let filtered): return filtered ? "No plays in these libraries" : "No watch history yet"
        }
    }

    package var message: String {
        switch self {
        case .unavailable: return "The local statistics store could not be opened."
        case .loading: return "Mirroring your Plex watch history…"
        case .empty(let filtered): return filtered ? "Switch on more libraries with the filter button." : "Play something and your stats will appear here."
        }
    }
}
