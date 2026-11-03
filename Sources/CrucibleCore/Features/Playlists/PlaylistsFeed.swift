import Foundation
import MidgarCore

/// The address Plex wants for items it should put in a playlist: the server, the library agent and the rating keys.
package enum PlexItemURI {
    package static func make(machineIdentifier: String, ratingKeys: [String]) -> String {
        "server://\(machineIdentifier)/com.plexapp.plugins.library/library/metadata/\(ratingKeys.joined(separator: ","))"
    }
}

/// Reads the viewer's video playlists and what is in them.
package enum PlaylistsFeed {
    private static let pageSize = 200

    /// The playlists a viewer can add to are the ones they build by hand; a smart playlist fills itself.
    package static func playlists(api: APIClient) async throws -> [PlexMetadata] {
        let container = try await api.requestContainer(.playlists)
        return (container.Metadata ?? []).filter { $0.mediaType == "playlist" }
    }

    package static func items(inPlaylist ratingKey: String, api: APIClient) async throws -> [PlexMetadata] {
        var all: [PlexMetadata] = []
        var start = 0
        while true {
            let container = try await api.requestContainer(.playlistItems(ratingKey: ratingKey, start: start, size: pageSize))
            try Task.checkCancellation()
            let page = container.Metadata ?? []
            all.append(contentsOf: page)
            start += page.count
            let total = container.totalSize ?? container.size ?? start
            guard !page.isEmpty, start < total else { return all }
        }
    }
}

/// Builds and edits playlists.
package enum PlaylistService {
    /// Playlists the viewer can add titles to.
    package static func editable(_ playlists: [PlexMetadata]) -> [PlexMetadata] {
        playlists.filter { !$0.isSmart }
    }

    /// Makes a playlist called `title` holding `ratingKeys`, and returns it. A playlist needs at least one title when it is made.
    /// `machineIdentifier` is the server's own, read from the saved server or the server itself when nil.
    package static func create(title: String, adding ratingKeys: [String], machineIdentifier: String? = nil, api: APIClient) async throws -> PlexMetadata? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !ratingKeys.isEmpty else { return nil }
        let machine = try await resolveMachineIdentifier(machineIdentifier, api: api)
        let uri = PlexItemURI.make(machineIdentifier: machine, ratingKeys: ratingKeys)
        return try await log("Create playlist") {
            let container = try await api.requestContainer(.createPlaylist(title: name, uri: uri))
            return container.Metadata?.first
        }
    }

    package static func add(_ ratingKeys: [String], toPlaylist playlist: String, machineIdentifier: String? = nil, api: APIClient) async throws {
        guard !ratingKeys.isEmpty else { return }
        let machine = try await resolveMachineIdentifier(machineIdentifier, api: api)
        let uri = PlexItemURI.make(machineIdentifier: machine, ratingKeys: ratingKeys)
        try await log("Add to playlist \(playlist)") {
            try await api.requestConfirmed(.addToPlaylist(ratingKey: playlist, uri: uri))
        }
    }

    package static func remove(playlistItemID: Int, fromPlaylist playlist: String, api: APIClient) async throws {
        try await log("Remove from playlist \(playlist)") {
            try await api.requestConfirmed(.removeFromPlaylist(ratingKey: playlist, playlistItemID: playlistItemID))
        }
    }

    /// Moves one entry to follow `after` (an entry's `playlistItemID`), or to the front for nil.
    package static func move(playlistItemID: Int, after: Int?, inPlaylist playlist: String, api: APIClient) async throws {
        try await log("Move in playlist \(playlist)") {
            try await api.requestConfirmed(.movePlaylistItem(ratingKey: playlist, playlistItemID: playlistItemID, after: after))
        }
    }

    package static func delete(playlist: String, api: APIClient) async throws {
        try await log("Delete playlist \(playlist)") {
            try await api.requestConfirmed(.deletePlaylist(ratingKey: playlist))
        }
    }

    /// The `playlistItemID` an entry moved to the position `target` of `entries` must follow, or nil for the front.
    package static func anchor(movingFrom source: Int, to target: Int, in entries: [PlexMetadata]) -> Int? {
        guard entries.indices.contains(source), entries.indices.contains(target), source != target else { return nil }
        var reordered = entries
        let moved = reordered.remove(at: source)
        reordered.insert(moved, at: target)
        guard target > 0 else { return nil }
        return reordered[target - 1].playlistItemID
    }

    private static func resolveMachineIdentifier(_ given: String?, api: APIClient) async throws -> String {
        if let given { return given }
        if let saved = ServerBootstrap.savedMachineIdentifier, !saved.isEmpty { return saved }
        let identity: PlexIdentity = try await api.request(.identity)
        guard let id = identity.MediaContainer.machineIdentifier else { throw APIError.noServerConfigured }
        return id
    }

    private static func log<T>(_ action: String, _ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            MidgarLog.error("\(action) failed: \(error.localizedDescription)", category: .networking)
            throw error
        }
    }
}

/// What a playlist says about itself on its card.
package enum PlaylistFormat {
    /// "4 titles · 6 h 12 m", or whichever part the server reported.
    package static func subtitle(_ playlist: PlexMetadata) -> String? {
        var parts: [String] = []
        if let count = playlist.leafCount {
            parts.append(count == 1 ? String(localized: "1 title") : String(localized: "\(count) titles"))
        }
        if let runtime = DetailFormat.runtime(playlist.durationSecs) { parts.append(runtime) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    package static let newPlaylist = String(localized: "New Playlist…", comment: "Menu item that makes a playlist from the title")
    package static let addToPlaylist = String(localized: "Add to Playlist", comment: "Menu title for adding a title to one of the viewer's playlists")
    package static let namePrompt = String(localized: "Name your playlist", comment: "Prompt of the dialog that makes a new playlist")
    package static let namePlaceholder = String(localized: "Playlist name", comment: "Placeholder of the new playlist's name field")
    package static let create = String(localized: "Create", comment: "Button that makes the new playlist")
}
