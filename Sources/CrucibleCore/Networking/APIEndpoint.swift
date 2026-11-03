import Foundation

package enum PlexEndpoint: Sendable {
    case requestPin(strong: Bool)
    case checkPin(pinId: Int)
    case resources

    case identity
    case sections
    case sectionItems(sectionId: String, sort: String? = nil, genre: String? = nil, start: Int = 0, size: Int = 50, unwatched: Bool = false, inProgress: Bool = false, actor: String? = nil)
    case sectionGenres(sectionId: String)
    case sectionFirstCharacter(sectionId: String)
    case sectionFolder(sectionId: String)
    case sectionCollections(sectionId: String, start: Int = 0, size: Int = 200)
    case collectionItems(ratingKey: String, start: Int = 0, size: Int = 200)
    case folderPath(String)
    case metadata(ratingKey: String)
    case children(ratingKey: String)
    case hubs(count: Int = 20)
    case sectionHubs(sectionId: String)
    case onDeck
    case recentlyAdded(start: Int = 0, size: Int = 50)
    case search(query: String)
    case serverSessions

    case playlists
    case playlistItems(ratingKey: String, start: Int = 0, size: Int = 200)
    case createPlaylist(title: String, uri: String)
    case addToPlaylist(ratingKey: String, uri: String)
    case removeFromPlaylist(ratingKey: String, playlistItemID: Int)
    case movePlaylistItem(ratingKey: String, playlistItemID: Int, after: Int?)
    case deletePlaylist(ratingKey: String)

    case scrobble(ratingKey: String)
    case unscrobble(ratingKey: String)
    case rate(ratingKey: String, rating: Int)
    case timeline(ratingKey: String, state: String, timeMs: Int, durationMs: Int)
    case progress(ratingKey: String, timeMs: Int)
    case history(start: Int = 0, size: Int = 50, sort: String? = "viewedAt:desc")
    case sectionHistory(sectionId: String, size: Int = 100)

    case stopTranscode(session: String)
    case pingTranscode(session: String)

    var isPlexTV: Bool {
        switch self {
        case .requestPin, .checkPin, .resources: return true
        default: return false
        }
    }

    static var plexTVBaseURL: URL { PlexTVHost.clients }

    package var timeout: TimeInterval {
        switch self {
        case .scrobble, .unscrobble, .rate, .timeline, .progress, .stopTranscode, .pingTranscode, .addToPlaylist, .removeFromPlaylist, .movePlaylistItem, .deletePlaylist:
            return 10
        default:
            return 15
        }
    }

    var method: String {
        switch self {
        case .requestPin:
            return "POST"
        case .stopTranscode, .removeFromPlaylist, .deletePlaylist:
            return "DELETE"
        case .rate, .addToPlaylist, .movePlaylistItem:
            return "PUT"
        case .createPlaylist:
            return "POST"
        default:
            return "GET"
        }
    }

    package var path: String {
        switch self {
        case .requestPin:
            return "/api/v2/pins"
        case .checkPin(let pinId):
            return "/api/v2/pins/\(pinId)"
        case .resources:
            return "/api/v2/resources"
        case .identity:
            return "/identity"
        case .sections:
            return "/library/sections"
        case .sectionFolder(let sectionId):
            return "/library/sections/\(sectionId)/folder"
        case .folderPath(let path):
            return path
        case .sectionItems(let sectionId, _, _, _, _, _, _, _):
            return "/library/sections/\(sectionId)/all"
        case .sectionFirstCharacter(let sectionId):
            return "/library/sections/\(sectionId)/firstCharacter"
        case .sectionGenres(let sectionId):
            return "/library/sections/\(sectionId)/genre"
        case .metadata(let ratingKey):
            return "/library/metadata/\(ratingKey)"
        case .children(let ratingKey):
            return "/library/metadata/\(ratingKey)/children"
        case .hubs:
            return "/hubs"
        case .sectionHubs(let sectionId):
            return "/hubs/sections/\(sectionId)"
        case .onDeck:
            return "/library/onDeck"
        case .recentlyAdded:
            return "/library/recentlyAdded"
        case .search:
            return "/hubs/search"
        case .serverSessions:
            return "/status/sessions"
        case .sectionCollections(let sectionId, _, _):
            return "/library/sections/\(sectionId)/collections"
        case .collectionItems(let ratingKey, _, _):
            return "/library/collections/\(ratingKey)/children"
        case .playlists, .createPlaylist:
            return "/playlists"
        case .playlistItems(let ratingKey, _, _), .addToPlaylist(let ratingKey, _):
            return "/playlists/\(ratingKey)/items"
        case .removeFromPlaylist(let ratingKey, let playlistItemID):
            return "/playlists/\(ratingKey)/items/\(playlistItemID)"
        case .movePlaylistItem(let ratingKey, let playlistItemID, _):
            return "/playlists/\(ratingKey)/items/\(playlistItemID)/move"
        case .deletePlaylist(let ratingKey):
            return "/playlists/\(ratingKey)"
        case .scrobble:
            return "/:/scrobble"
        case .unscrobble:
            return "/:/unscrobble"
        case .rate:
            return "/:/rate"
        case .timeline:
            return "/:/timeline"
        case .progress:
            return "/:/progress"
        case .history, .sectionHistory:
            return "/status/sessions/history/all"
        case .stopTranscode:
            return "/video/:/transcode/universal/stop"
        case .pingTranscode:
            return "/video/:/transcode/universal/ping"
        }
    }

    package var queryItems: [URLQueryItem]? {
        switch self {
        case .metadata:
            return [
                URLQueryItem(name: "includeMarkers", value: "1"),
                URLQueryItem(name: "includeRelated", value: "1"),
                URLQueryItem(name: "includeRelatedCount", value: "10"),
            ]
        case .resources:
            return [
                URLQueryItem(name: "includeHttps", value: "1"),
                URLQueryItem(name: "includeRelay", value: "1"),
            ]
        case .sectionItems(_, let sort, let genre, let start, let size, let unwatched, let inProgress, let actor):
            var items = [
                URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
                URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)"),
            ]
            if let sort { items.append(URLQueryItem(name: "sort", value: sort)) }
            if let genre { items.append(URLQueryItem(name: "genre", value: genre)) }
            if unwatched { items.append(URLQueryItem(name: "unwatched", value: "1")) }
            if inProgress { items.append(URLQueryItem(name: "inProgress", value: "1")) }
            if let actor { items.append(URLQueryItem(name: "actor", value: actor)) }
            return items
        case .sectionCollections(_, let start, let size), .collectionItems(_, let start, let size), .playlistItems(_, let start, let size):
            return [
                URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
                URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)"),
            ]
        case .playlists:
            return [URLQueryItem(name: "playlistType", value: "video")]
        case .createPlaylist(let title, let uri):
            return [
                URLQueryItem(name: "type", value: "video"),
                URLQueryItem(name: "title", value: title),
                URLQueryItem(name: "smart", value: "0"),
                URLQueryItem(name: "uri", value: uri),
            ]
        case .addToPlaylist(_, let uri):
            return [URLQueryItem(name: "uri", value: uri)]
        case .movePlaylistItem(_, _, let after):
            return after.map { [URLQueryItem(name: "after", value: "\($0)")] }
        case .hubs(let count):
            return [URLQueryItem(name: "count", value: "\(count)")]
        case .recentlyAdded(let start, let size):
            return [
                URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
                URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)"),
            ]
        case .search(let query):
            return [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "includeCollections", value: "0"),
                URLQueryItem(name: "includeExternalMedia", value: "0"),
            ]
        case .scrobble(let ratingKey):
            return [
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                URLQueryItem(name: "key", value: ratingKey),
            ]
        case .unscrobble(let ratingKey):
            return [
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                URLQueryItem(name: "key", value: ratingKey),
            ]
        case .rate(let ratingKey, let rating):
            return [
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                URLQueryItem(name: "key", value: ratingKey),
                URLQueryItem(name: "rating", value: "\(rating)"),
            ]
        case .timeline(let ratingKey, let state, let timeMs, let durationMs):
            return [
                URLQueryItem(name: "ratingKey", value: ratingKey),
                URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "time", value: "\(timeMs)"),
                URLQueryItem(name: "duration", value: "\(durationMs)"),
            ]
        case .progress(let ratingKey, let timeMs):
            return [
                URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                URLQueryItem(name: "time", value: "\(timeMs)"),
            ]
        case .history(let start, let size, let sort):
            var items = [
                URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
                URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)"),
            ]
            if let sort { items.append(URLQueryItem(name: "sort", value: sort)) }
            return items
        case .sectionHistory(let sectionId, let size):
            return [
                URLQueryItem(name: "librarySectionID", value: sectionId),
                URLQueryItem(name: "sort", value: "viewedAt:desc"),
                URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
                URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)"),
            ]
        case .stopTranscode(let session):
            return [URLQueryItem(name: "session", value: session)]
        case .pingTranscode(let session):
            return [URLQueryItem(name: "session", value: session)]
        default:
            return nil
        }
    }

    package func urlRequest(baseURL: URL, token: String?) throws -> URLRequest {
        let base = isPlexTV ? Self.plexTVBaseURL : baseURL
        let baseString = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: baseString + path) else {
            throw APIError.invalidURL
        }
        if let queryItems {
            components.queryItems = queryItems
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout

        for (key, value) in PlexHeaders.allHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if case .requestPin(let strong) = self {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.pinFormBody(strong: strong).data(using: .utf8)
        }

        return request
    }

    /// A strong PIN is the long code behind the `app.plex.tv/auth` page; omitting `strong` asks for
    /// the four character code a person types at plex.tv/link.
    static func pinFormBody(strong: Bool) -> String {
        let fields = (strong ? ["strong=true"] : []) + ["X-Plex-Product=Crucible", "X-Plex-Client-Identifier=\(PlexHeaders.clientIdentifier)"]
        return fields.joined(separator: "&")
    }
}
