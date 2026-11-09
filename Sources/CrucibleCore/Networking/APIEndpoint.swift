import Foundation

package enum PlexEndpoint: Sendable {
    case requestPin(strong: Bool)
    case checkPin(pinId: Int)
    case resources

    case identity
    /// The server's root, which says what operating system it runs on.
    case serverRoot
    case sections
    case sectionItems(sectionId: String, sort: String? = nil, genre: String? = nil, start: Int = 0, size: Int = 50, unwatched: Bool = false, inProgress: Bool = false, actor: String? = nil, filters: [String: String] = [:])
    case sectionGenres(sectionId: String)
    case sectionFacet(sectionId: String, facet: String)
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
    case removeFromContinueWatching(ratingKey: String)
    case recentlyAdded(start: Int = 0, size: Int = 50)
    case search(query: String)
    case serverSessions
    case watchlist(start: Int = 0, size: Int = 100)
    case catalogMetadata(key: String)
    case addToWatchlist(guid: String)
    case removeFromWatchlist(guid: String)
    case searchSubtitles(ratingKey: String, language: String, hearingImpaired: Bool, forced: Bool)
    case downloadSubtitle(ratingKey: String, query: [URLQueryItem])

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

    case scanSection(sectionId: String, force: Bool)
    case analyzeSection(sectionId: String)
    case emptyTrash(sectionId: String)
    case refreshItem(ratingKey: String)
    case analyzeItem(ratingKey: String)
    case matches(ratingKey: String, title: String?, year: Int?)
    case match(ratingKey: String, guid: String, name: String, year: Int?)
    case unmatch(ratingKey: String)
    case editFields(sectionId: String, ratingKey: String, type: Int, values: [String: String])
    case artwork(ratingKey: String, kind: ArtworkKind)
    case selectArtwork(ratingKey: String, kind: ArtworkKind, url: String)
    case deleteItem(ratingKey: String)
    case terminateSession(sessionId: String, reason: String)
    case activities
    case cancelActivity(uuid: String)
    case updaterStatus
    case updaterCheck
    case updaterApply
    case resourceStatistics
    case deleteHistoryEntry(historyId: String)
    case itemPreferences(ratingKey: String)
    case setItemPreferences(ratingKey: String, values: [String: String])
    case eventSource
    case homeUsers
    case switchHomeUser(uuid: String, pin: String?)
    case account

    var isPlexTV: Bool {
        switch self {
        case .requestPin, .checkPin, .resources, .watchlist, .catalogMetadata, .addToWatchlist, .removeFromWatchlist, .homeUsers, .switchHomeUser, .account: return true
        default: return false
        }
    }

    static var plexTVBaseURL: URL { PlexTVHost.clients }

    /// The plex.tv host an account-level endpoint lives on.
    var plexTVHost: URL {
        switch self {
        case .watchlist, .catalogMetadata: return PlexTVHost.discover
        case .addToWatchlist, .removeFromWatchlist: return PlexTVHost.metadata
        case .account: return PlexTVHost.account
        default: return Self.plexTVBaseURL
        }
    }

    package var timeout: TimeInterval {
        switch self {
        case .scrobble, .unscrobble, .rate, .timeline, .progress, .stopTranscode, .pingTranscode, .addToPlaylist, .removeFromPlaylist, .movePlaylistItem, .deletePlaylist,
             .removeFromContinueWatching:
            return 10
        case .searchSubtitles, .downloadSubtitle, .matches:
            return 60
        case .eventSource:
            return ServerEventStream.idleTimeout
        default:
            return 15
        }
    }

    var method: String {
        switch self {
        case .analyzeSection, .emptyTrash, .refreshItem, .analyzeItem, .match, .unmatch, .editFields, .selectArtwork,
             .updaterCheck, .updaterApply, .setItemPreferences:
            return "PUT"
        case .deleteItem, .cancelActivity, .deleteHistoryEntry:
            return "DELETE"
        case .requestPin, .switchHomeUser:
            return "POST"
        case .stopTranscode, .removeFromPlaylist, .deletePlaylist:
            return "DELETE"
        case .rate, .addToPlaylist, .movePlaylistItem, .downloadSubtitle, .addToWatchlist, .removeFromWatchlist, .removeFromContinueWatching:
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
        case .serverRoot:
            return "/"
        case .sections:
            return "/library/sections"
        case .sectionFolder(let sectionId):
            return "/library/sections/\(sectionId)/folder"
        case .folderPath(let path):
            return path
        case .sectionItems(let sectionId, _, _, _, _, _, _, _, _):
            return "/library/sections/\(sectionId)/all"
        case .sectionFirstCharacter(let sectionId):
            return "/library/sections/\(sectionId)/firstCharacter"
        case .sectionGenres(let sectionId):
            return "/library/sections/\(sectionId)/genre"
        case .sectionFacet(let sectionId, let facet):
            return "/library/sections/\(sectionId)/\(facet)"
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
        case .removeFromContinueWatching:
            return "/actions/removeFromContinueWatching"
        case .recentlyAdded:
            return "/library/recentlyAdded"
        case .search:
            return "/hubs/search"
        case .serverSessions:
            return "/status/sessions"
        case .watchlist:
            return "/library/sections/watchlist/all"
        case .catalogMetadata(let key):
            return "/library/metadata/\(key)"
        case .addToWatchlist:
            return "/actions/addToWatchlist"
        case .removeFromWatchlist:
            return "/actions/removeFromWatchlist"
        case .searchSubtitles(let ratingKey, _, _, _), .downloadSubtitle(let ratingKey, _):
            return "/library/metadata/\(ratingKey)/subtitles"
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
        case .scanSection(let sectionId, _):
            return "/library/sections/\(sectionId)/refresh"
        case .analyzeSection(let sectionId):
            return "/library/sections/\(sectionId)/analyze"
        case .emptyTrash(let sectionId):
            return "/library/sections/\(sectionId)/emptyTrash"
        case .refreshItem(let ratingKey):
            return "/library/metadata/\(ratingKey)/refresh"
        case .analyzeItem(let ratingKey):
            return "/library/metadata/\(ratingKey)/analyze"
        case .matches(let ratingKey, _, _):
            return "/library/metadata/\(ratingKey)/matches"
        case .match(let ratingKey, _, _, _):
            return "/library/metadata/\(ratingKey)/match"
        case .unmatch(let ratingKey):
            return "/library/metadata/\(ratingKey)/unmatch"
        case .editFields(let sectionId, _, _, _):
            return "/library/sections/\(sectionId)/all"
        case .artwork(let ratingKey, let kind):
            return "/library/metadata/\(ratingKey)/\(kind.listPath)"
        case .selectArtwork(let ratingKey, let kind, _):
            return "/library/metadata/\(ratingKey)/\(kind.selectPath)"
        case .deleteItem(let ratingKey):
            return "/library/metadata/\(ratingKey)"
        case .terminateSession:
            return "/status/sessions/terminate"
        case .activities:
            return "/activities"
        case .cancelActivity(let uuid):
            return "/activities/\(uuid)"
        case .updaterStatus:
            return "/updater/status"
        case .updaterCheck:
            return "/updater/check"
        case .updaterApply:
            return "/updater/apply"
        case .resourceStatistics:
            return "/statistics/resources"
        case .deleteHistoryEntry(let historyId):
            return "/status/sessions/history/\(historyId)"
        case .itemPreferences(let ratingKey):
            return "/library/metadata/\(ratingKey)"
        case .setItemPreferences(let ratingKey, _):
            return "/library/metadata/\(ratingKey)/prefs"
        case .eventSource:
            return "/:/eventsource/notifications"
        case .homeUsers:
            return "/api/v2/home/users"
        case .switchHomeUser(let uuid, _):
            return "/api/v2/home/users/\(uuid)/switch"
        case .account:
            return "/api/v2/user"
        }
    }

    package var queryItems: [URLQueryItem]? {
        switch self {
        case .metadata:
            return [
                URLQueryItem(name: "includeGuids", value: "1"),
                URLQueryItem(name: "includeMarkers", value: "1"),
                URLQueryItem(name: "includeChapters", value: "1"),
                URLQueryItem(name: "includeRelated", value: "1"),
                URLQueryItem(name: "includeRelatedCount", value: "10"),
                URLQueryItem(name: "includeExtras", value: "1"),
            ]
        case .resources:
            return [
                URLQueryItem(name: "includeHttps", value: "1"),
                URLQueryItem(name: "includeRelay", value: "1"),
            ]
        case .sectionItems(_, let sort, let genre, let start, let size, let unwatched, let inProgress, let actor, let filters):
            var items = [
                URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
                URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)"),
            ]
            if let sort { items.append(URLQueryItem(name: "sort", value: sort)) }
            if let genre { items.append(URLQueryItem(name: "genre", value: genre)) }
            if unwatched { items.append(URLQueryItem(name: "unwatched", value: "1")) }
            if inProgress { items.append(URLQueryItem(name: "inProgress", value: "1")) }
            if let actor { items.append(URLQueryItem(name: "actor", value: actor)) }
            for (name, value) in filters.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: name, value: value)) }
            return items
        case .sectionCollections(_, let start, let size), .collectionItems(_, let start, let size), .playlistItems(_, let start, let size):
            return [
                URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
                URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)"),
            ]
        case .searchSubtitles(_, let language, let hearingImpaired, let forced):
            return [
                URLQueryItem(name: "language", value: language),
                URLQueryItem(name: "hearingImpaired", value: hearingImpaired ? "1" : "0"),
                URLQueryItem(name: "forced", value: forced ? "1" : "0"),
            ]
        case .downloadSubtitle(_, let query):
            return query
        case .watchlist(let start, let size):
            return [
                URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
                URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)"),
            ]
        case .addToWatchlist(let guid), .removeFromWatchlist(let guid):
            return [URLQueryItem(name: "ratingKey", value: WatchlistService.discoverKey(fromGuid: guid) ?? guid)]
        case .removeFromContinueWatching(let ratingKey):
            return [URLQueryItem(name: "ratingKey", value: ratingKey)]
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
        case .scanSection(_, let force):
            return force ? [URLQueryItem(name: "force", value: "1")] : nil
        case .matches(_, let title, let year):
            var items = [URLQueryItem(name: "manual", value: "1")]
            if let title, !title.isEmpty { items.append(URLQueryItem(name: "title", value: title)) }
            if let year { items.append(URLQueryItem(name: "year", value: "\(year)")) }
            return items
        case .match(_, let guid, let name, let year):
            var items = [URLQueryItem(name: "guid", value: guid), URLQueryItem(name: "name", value: name)]
            if let year { items.append(URLQueryItem(name: "year", value: "\(year)")) }
            return items
        case .editFields(_, let ratingKey, let type, let values):
            return [URLQueryItem(name: "type", value: "\(type)"), URLQueryItem(name: "id", value: ratingKey)]
                + values.sorted { $0.key < $1.key }.flatMap { field, value in
                    [URLQueryItem(name: "\(field).value", value: value), URLQueryItem(name: "\(field).locked", value: "1")]
                }
        case .selectArtwork(_, _, let url):
            return [URLQueryItem(name: "url", value: url)]
        case .terminateSession(let sessionId, let reason):
            return [URLQueryItem(name: "sessionId", value: sessionId), URLQueryItem(name: "reason", value: reason)]
        case .updaterCheck:
            return [URLQueryItem(name: "download", value: "0")]
        case .updaterApply:
            return [URLQueryItem(name: "tonight", value: "0"), URLQueryItem(name: "skip", value: "0")]
        case .resourceStatistics:
            return [URLQueryItem(name: "timespan", value: "6")]
        case .itemPreferences:
            return [URLQueryItem(name: "includePreferences", value: "1")]
        case .eventSource:
            return [URLQueryItem(name: "filters", value: ServerEventStream.filters)]
        case .setItemPreferences(_, let values):
            return values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        case .pingTranscode(let session):
            return [URLQueryItem(name: "session", value: session)]
        default:
            return nil
        }
    }

    package func urlRequest(baseURL: URL, token: String?) throws -> URLRequest {
        let base = isPlexTV ? plexTVHost : baseURL
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
        if case .switchHomeUser(_, let pin) = self {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.switchFormBody(pin: pin).data(using: .utf8)
        }

        return request
    }

    /// A strong PIN is the long code behind the `app.plex.tv/auth` page; omitting `strong` asks for
    /// the four character code a person types at plex.tv/link.
    /// The profile's PIN, percent-encoded, beside the client that asks; no PIN for a profile without one.
    static func switchFormBody(pin: String?) -> String {
        var components = URLComponents()
        components.queryItems = (pin.map { [URLQueryItem(name: "pin", value: $0)] } ?? []) + [URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexHeaders.clientIdentifier)]
        return components.percentEncodedQuery ?? ""
    }

    static func pinFormBody(strong: Bool) -> String {
        let fields = (strong ? ["strong=true"] : []) + ["X-Plex-Product=Crucible", "X-Plex-Client-Identifier=\(PlexHeaders.clientIdentifier)"]
        return fields.joined(separator: "&")
    }
}
