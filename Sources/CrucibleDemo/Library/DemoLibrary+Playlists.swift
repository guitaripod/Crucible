import Foundation

/// A playlist the viewer can edit, as the demo remembers it between launches.
struct DemoPlaylistState: Codable {
    struct Entry: Codable {
        var itemID: Int
        var ratingKey: String
    }

    var ratingKey: String
    var title: String
    var entries: [Entry]
    var addedAt: Int
}

extension DemoLibrary {
    private static let seedPlaylists: [(title: String, keys: [String])] = [
        ("Friday Night", ["1006", "1004", "1007"]),
        ("Sci-Fi Marathon", ["1002", "1008", "1013", "1011"]),
    ]

    func seedPlaylistsIfNeeded() {
        if let saved = persisted.playlists {
            playlists = saved
            nextEntryID = persisted.nextEntryID ?? nextEntryID
            nextPlaylistKey = persisted.nextPlaylistKey ?? nextPlaylistKey
            return
        }
        for seed in Self.seedPlaylists where viewer.isAdmin {
            _ = makePlaylist(title: seed.title, keys: seed.keys)
        }
    }

    func playlistsResponse() -> DemoResponse {
        let metadata = playlists.map(playlistJSON)
        return .container(["size": metadata.count, "Metadata": metadata])
    }

    func playlistItemsResponse(_ ratingKey: String, request: DemoRequest) -> DemoResponse {
        guard let playlist = playlists.first(where: { $0.ratingKey == ratingKey }) else { return .notFound() }
        let entries = playlist.entries.compactMap { entry -> DemoJSON? in
            guard var json = render(entry.ratingKey) else { return nil }
            json["playlistItemID"] = entry.itemID
            return json
        }
        let start = max(0, request.int("X-Plex-Container-Start") ?? 0)
        let size = max(0, request.int("X-Plex-Container-Size") ?? entries.count)
        let page = Array(entries.dropFirst(start).prefix(size))
        return .container(["size": page.count, "totalSize": entries.count, "offset": start, "key": ratingKey,
                           "title": playlist.title, "Metadata": page])
    }

    func createPlaylist(title: String, uri: String) -> DemoResponse {
        let keys = Self.ratingKeys(in: uri).filter { items[$0]?.isPlayable == true }
        guard !title.isEmpty, !keys.isEmpty else { return .empty(400) }
        let playlist = makePlaylist(title: title, keys: keys)
        savePlaylists()
        return .container(["size": 1, "Metadata": [playlistJSON(playlist)]])
    }

    func addToPlaylist(_ ratingKey: String, uri: String) -> DemoResponse {
        guard let index = playlists.firstIndex(where: { $0.ratingKey == ratingKey }) else { return .notFound() }
        for key in Self.ratingKeys(in: uri) where items[key]?.isPlayable == true {
            playlists[index].entries.append(.init(itemID: takeEntryID(), ratingKey: key))
        }
        savePlaylists()
        return .container(["size": 1, "Metadata": [playlistJSON(playlists[index])]])
    }

    func removeFromPlaylist(_ ratingKey: String, itemID: Int) -> DemoResponse {
        guard let index = playlists.firstIndex(where: { $0.ratingKey == ratingKey }) else { return .notFound() }
        playlists[index].entries.removeAll { $0.itemID == itemID }
        savePlaylists()
        return .empty()
    }

    func movePlaylistItem(_ ratingKey: String, itemID: Int, after: Int?) -> DemoResponse {
        guard let index = playlists.firstIndex(where: { $0.ratingKey == ratingKey }),
              let from = playlists[index].entries.firstIndex(where: { $0.itemID == itemID }) else { return .notFound() }
        let entry = playlists[index].entries.remove(at: from)
        let destination = after.flatMap { anchor in playlists[index].entries.firstIndex { $0.itemID == anchor } }.map { $0 + 1 } ?? 0
        playlists[index].entries.insert(entry, at: destination)
        savePlaylists()
        return .empty()
    }

    func deletePlaylist(_ ratingKey: String) -> DemoResponse {
        playlists.removeAll { $0.ratingKey == ratingKey }
        savePlaylists()
        return .empty()
    }

    private func makePlaylist(title: String, keys: [String]) -> DemoPlaylistState {
        let playlist = DemoPlaylistState(
            ratingKey: "\(nextPlaylistKey)", title: title,
            entries: keys.map { .init(itemID: takeEntryID(), ratingKey: $0) }, addedAt: now
        )
        nextPlaylistKey += 1
        playlists.append(playlist)
        return playlist
    }

    private func takeEntryID() -> Int {
        defer { nextEntryID += 1 }
        return nextEntryID
    }

    private func savePlaylists() {
        persisted.playlists = playlists
        persisted.nextEntryID = nextEntryID
        persisted.nextPlaylistKey = nextPlaylistKey
        save()
    }

    /// The rating keys a `server://machine/com.plexapp.plugins.library/library/metadata/1,2` address names.
    private static func ratingKeys(in uri: String) -> [String] {
        guard let range = uri.range(of: "/library/metadata/") else { return [] }
        return uri[range.upperBound...].split(separator: ",").map(String.init)
    }

    private func playlistJSON(_ playlist: DemoPlaylistState) -> DemoJSON {
        let members = playlist.entries.compactMap { items[$0.ratingKey] }
        var json: DemoJSON = [
            "ratingKey": playlist.ratingKey, "key": "/playlists/\(playlist.ratingKey)/items",
            "guid": "com.plexapp.plugins.playlist://\(playlist.ratingKey)", "type": "playlist", "title": playlist.title,
            "summary": "", "smart": false, "playlistType": "video", "leafCount": members.count,
            "duration": members.reduce(0) { $0 + $1.durationMs }, "addedAt": playlist.addedAt, "updatedAt": now,
        ]
        if let artwork = members.first?.fields.string("thumb") {
            json["composite"] = artwork
        }
        return json
    }
}

extension DemoLibrary {
    /// Two people watching right now, so Server Activity has something to show: one film playing and one episode paused and converted.
    func sessionsResponse() -> DemoResponse {
        let episode = showKeys.first.flatMap { episodeKeysByShow[$0]?.dropFirst(3).first }
        let specs: [(key: String?, user: String, device: String, product: String, state: String, transcodes: Bool)] = [
            ("1001", "Maren", "Living Room Apple TV", "Plex for Apple TV", "playing", false),
            (episode, "Idris", "Office", "Plex Web", "paused", true),
        ]
        let sessions = specs.compactMap { spec -> DemoJSON? in
            guard let key = spec.key, !stoppedSessions.contains("demo-\(key)"), var json = render(key) else { return nil }
            json["viewOffset"] = (items[key]?.durationMs ?? 0) / 3
            json["User"] = ["id": "2", "title": spec.user]
            json["Player"] = ["title": spec.device, "product": spec.product, "state": spec.state, "local": true]
            json["Session"] = ["id": "demo-\(key)", "location": "lan"]
            if spec.transcodes {
                json["TranscodeSession"] = ["videoDecision": "transcode", "audioDecision": "copy"]
            }
            return json
        }
        return .container(["size": sessions.count, "Metadata": sessions])
    }
}
