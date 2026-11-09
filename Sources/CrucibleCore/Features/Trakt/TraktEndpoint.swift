import Foundation

/// The kind of item a Trakt id lookup or a scrobble names.
package enum TraktMediaKind: String, Codable, Sendable {
    case movie, show, episode
}

/// The outside id a Plex item carries that Trakt can look it up by.
package enum TraktLookupID: Hashable, Sendable {
    case imdb(String)
    case tmdb(Int)
    case tvdb(Int)

    var pathType: String {
        switch self {
        case .imdb: return "imdb"
        case .tmdb: return "tmdb"
        case .tvdb: return "tvdb"
        }
    }

    var pathValue: String {
        switch self {
        case .imdb(let id): return id
        case .tmdb(let id): return String(id)
        case .tvdb(let id): return String(id)
        }
    }

    /// Whether `ids` names the same item this id does, which is how a lookup proves it found the right one.
    func matches(_ ids: TraktIDs) -> Bool {
        switch self {
        case .imdb(let id): return ids.imdb == id
        case .tmdb(let id): return ids.tmdb == id
        case .tvdb(let id): return ids.tvdb == id
        }
    }
}

/// What a scrobble says happened.
package enum TraktScrobbleAction: String, Sendable {
    case start, pause, stop
}

/// Every Trakt route Crucible calls, with its method, path, query, body and whether it needs the viewer's token.
package enum TraktEndpoint: Sendable {
    case deviceCode
    case deviceToken(deviceCode: String)
    case refreshToken(String)
    case revoke(accessToken: String)
    case userSettings
    case plexSettings
    case disablePlexScrobbler
    case lookup(TraktLookupID, kind: TraktMediaKind)
    case episode(showID: Int, season: Int, number: Int)
    case scrobble(TraktScrobbleAction, kind: TraktMediaKind, ids: TraktIDs, progress: Double)
    case addHistory(TraktSyncItems)
    case removeHistory(TraktSyncItems)
    case addRatings(TraktSyncItems)
    case removeRatings(TraktSyncItems)
    case checkin(kind: TraktMediaKind, ids: TraktIDs)
    case cancelCheckin
    case ratings(kind: TraktMediaKind, ids: TraktIDs, season: Int?, number: Int?, showID: Int?)
    /// One page of everything the viewer watched, newest first, with runtimes, genres and posters; from `startAt` on when given.
    case history(page: Int, limit: Int, startAt: Date?)

    /// The redirect URI device-code tokens are refreshed with: they were issued without a browser redirect.
    static let deviceRedirectURI = "urn:ietf:wg:oauth:2.0:oob"

    package var method: String {
        switch self {
        case .userSettings, .plexSettings, .lookup, .episode, .ratings, .history: return "GET"
        case .disablePlexScrobbler: return "PUT"
        case .cancelCheckin: return "DELETE"
        default: return "POST"
        }
    }

    package var isWrite: Bool { method != "GET" && !isAuthFlow }

    /// The sign-in calls, which never carry the viewer's token and are polled at the interval Trakt sets.
    package var isAuthFlow: Bool {
        switch self {
        case .deviceCode, .deviceToken, .refreshToken, .revoke: return true
        default: return false
        }
    }

    package var requiresToken: Bool {
        switch self {
        case .deviceCode, .deviceToken, .refreshToken, .revoke, .lookup, .episode, .ratings: return false
        default: return true
        }
    }

    package var path: String {
        switch self {
        case .deviceCode: return "/oauth/device/code"
        case .deviceToken: return "/oauth/device/token"
        case .refreshToken: return "/oauth/token"
        case .revoke: return "/oauth/revoke"
        case .userSettings: return "/users/settings"
        case .plexSettings, .disablePlexScrobbler: return "/users/settings/plex"
        case .lookup(let id, _): return "/search/\(id.pathType)/\(id.pathValue.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id.pathValue)"
        case .episode(let showID, let season, let number): return "/shows/\(showID)/seasons/\(season)/episodes/\(number)"
        case .scrobble(let action, _, _, _): return "/scrobble/\(action.rawValue)"
        case .addHistory: return "/sync/history"
        case .removeHistory: return "/sync/history/remove"
        case .addRatings: return "/sync/ratings"
        case .removeRatings: return "/sync/ratings/remove"
        case .checkin, .cancelCheckin: return "/checkin"
        case .history: return "/sync/history"
        case .ratings(let kind, let ids, let season, let number, let showID):
            switch kind {
            case .movie: return "/movies/\(ids.trakt.map(String.init) ?? ids.slug ?? "")/ratings"
            case .show: return "/shows/\(ids.trakt.map(String.init) ?? ids.slug ?? "")/ratings"
            case .episode: return "/shows/\(showID.map(String.init) ?? "")/seasons/\(season ?? 0)/episodes/\(number ?? 0)/ratings"
            }
        }
    }

    package var queryItems: [URLQueryItem] {
        switch self {
        case .lookup(_, let kind): return [URLQueryItem(name: "type", value: kind.rawValue)]
        case .ratings: return [URLQueryItem(name: "extended", value: "all")]
        case .history(let page, let limit, let startAt):
            var items = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "extended", value: "full,images"),
            ]
            if let startAt { items.append(URLQueryItem(name: "start_at", value: ISO8601DateFormatter().string(from: startAt))) }
            return items
        default: return []
        }
    }

    /// The JSON body, or nil for a call without one.
    package func body(clientID: String) throws -> Data? {
        let encoder = JSONEncoder()
        switch self {
        case .deviceCode:
            return try encoder.encode(["client_id": clientID])
        case .deviceToken(let deviceCode):
            return try encoder.encode(["code": deviceCode, "client_id": clientID])
        case .refreshToken(let refreshToken):
            return try encoder.encode([
                "refresh_token": refreshToken,
                "client_id": clientID,
                "redirect_uri": Self.deviceRedirectURI,
                "grant_type": "refresh_token",
            ])
        case .revoke(let accessToken):
            return try encoder.encode(["token": accessToken, "client_id": clientID])
        case .disablePlexScrobbler:
            let off = ["watching": false, "watched": false]
            return try encoder.encode(["scrobbler": ["toggles": ["movie": off, "episode": off]]])
        case .scrobble(_, let kind, let ids, let progress):
            return try encoder.encode(ScrobbleBody(kind: kind, ids: ids, progress: progress))
        case .addHistory(let items), .removeHistory(let items), .addRatings(let items), .removeRatings(let items):
            return try encoder.encode(items)
        case .checkin(let kind, let ids):
            return try encoder.encode(ScrobbleBody(kind: kind, ids: ids, progress: nil))
        case .userSettings, .plexSettings, .lookup, .episode, .cancelCheckin, .ratings, .history:
            return nil
        }
    }

    /// The body of a scrobble or a check-in: the item under its kind's key, and the progress for a scrobble.
    private struct ScrobbleBody: Encodable {
        let kind: TraktMediaKind
        let ids: TraktIDs
        let progress: Double?

        private struct Item: Encodable { let ids: TraktIDs }
        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ string: String) { stringValue = string }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(Item(ids: ids), forKey: Key(kind.rawValue))
            if let progress { try container.encode((progress * 100).rounded() / 100, forKey: Key("progress")) }
        }
    }

    package func urlRequest(token: String?, clientID: String) throws -> URLRequest {
        let base = isAuthFlow ? TraktConfig.authURL : TraktConfig.apiURL
        guard var components = URLComponents(url: base.appendingPathComponent(String(path.dropFirst())), resolvingAgainstBaseURL: false) else {
            throw TraktError.invalidRequest
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw TraktError.invalidRequest }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue(TraktConfig.userAgent, forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try body(clientID: clientID)
        return request
    }
}
