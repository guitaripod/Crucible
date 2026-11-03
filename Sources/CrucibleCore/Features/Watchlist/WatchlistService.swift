import Foundation
import MidgarCore

/// The viewer's Plex watchlist: titles saved to watch later, kept on the account rather than on any one server.
package enum WatchlistService {
    private static let pageSize = 100

    /// Everything on the watchlist, newest first as the account lists it.
    package static func items(token: String) async throws -> [PlexMetadata] {
        let token = plexTV(token)
        var all: [PlexMetadata] = []
        var start = 0
        while true {
            let response: PlexResponse = try await APIClient.plexTVRequest(.watchlist(start: start, size: pageSize), token: token)
            try Task.checkCancellation()
            let page = response.MediaContainer.Metadata ?? []
            all.append(contentsOf: page)
            start += page.count
            let total = response.MediaContainer.totalSize ?? response.MediaContainer.size ?? start
            guard !page.isEmpty, start < total else { return all }
        }
    }

    package static func add(guid: String, token: String) async throws {
        try await change(.addToWatchlist(guid: guid), token: token)
    }

    package static func remove(guid: String, token: String) async throws {
        try await change(.removeFromWatchlist(guid: guid), token: token)
    }

    /// The watchlist belongs to whoever is watching: a Home profile's lives behind its own plex.tv token, not the server token
    /// screens hold.
    private static func plexTV(_ token: String) -> String {
        HomeProfiles.activePlexTVToken ?? token
    }

    private static func change(_ endpoint: PlexEndpoint, token: String) async throws {
        do {
            try await APIClient.plexTVRequestVoid(endpoint, token: plexTV(token))
        } catch {
            MidgarLog.error("Watchlist change failed: \(error.localizedDescription)", category: .networking)
            throw error
        }
    }

    /// The key plex.tv knows a title by: the last part of its `plex://movie/<key>` guid.
    package static func discoverKey(fromGuid guid: String) -> String? {
        guard guid.hasPrefix("plex://") else { return nil }
        let parts = guid.dropFirst("plex://".count).split(separator: "/")
        guard parts.count >= 2, let last = parts.last else { return nil }
        return String(last)
    }

    package static func contains(guid: String?, in watchlist: [PlexMetadata]) -> Bool {
        guard let guid else { return false }
        return watchlist.contains { $0.guid == guid }
    }

    /// The title on the viewer's server that a watchlist entry is, found by guid in a search for its name, or nil when the server does not have it.
    package static func localMatch(for entry: PlexMetadata, api: APIClient) async throws -> PlexMetadata? {
        let container = try await api.requestContainer(.search(query: entry.title))
        let candidates = (container.Hub ?? []).flatMap { $0.Metadata ?? [] }.filter { ["movie", "show"].contains($0.mediaType) }
        if let guid = entry.guid, let exact = candidates.first(where: { $0.guid == guid }) { return exact }
        return candidates.first { $0.guid == nil && $0.title.lowercased() == entry.title.lowercased() && $0.year == entry.year }
    }

    package static let title = String(localized: "Watchlist", comment: "Name of the list of titles saved to watch later")
    package static let emptyTitle = String(localized: "Your Watchlist Is Empty", comment: "Title of the watchlist when nothing is saved")
    package static let emptyText = String(localized: "Titles you add to your Plex watchlist appear here.", comment: "Message of the watchlist when nothing is saved")
    package static let add = String(localized: "Add to Watchlist", comment: "Menu item that saves a title to the Plex watchlist")
    package static let remove = String(localized: "Remove from Watchlist", comment: "Menu item that takes a title off the Plex watchlist")
    package static let notInLibraryTitle = String(localized: "Not in Your Library", comment: "Title of the message shown when a watchlist title is not on the viewer's server")
    package static let notInLibraryText = String(localized: "This title is on your watchlist, but your server does not have it.", comment: "Message shown when a watchlist title is not on the viewer's server")
}
