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
        case .unavailable: return String(localized: "Statistics unavailable")
        case .loading: return String(localized: "Building your statistics")
        case .empty(let filtered): return filtered ? String(localized: "No plays in these libraries") : String(localized: "No watch history yet")
        }
    }

    package var message: String {
        switch self {
        case .unavailable: return String(localized: "The local statistics store could not be opened.")
        case .loading: return String(localized: "Mirroring your Plex watch history…")
        case .empty(let filtered): return filtered ? String(localized: "Switch on more libraries with the filter button.") : String(localized: "Play something and your stats will appear here.")
        }
    }
}
