import Foundation

enum PlexEndpoint: Sendable {
    case requestPin
    case checkPin(pinId: Int)
    case resources

    case identity
    case sections
    case sectionItems(sectionId: String, sort: String? = nil, genre: String? = nil, start: Int = 0, size: Int = 50)
    case sectionGenres(sectionId: String)
    case sectionFolder(sectionId: String)
    case folderPath(String)
    case metadata(ratingKey: String)
    case children(ratingKey: String)
    case hubs(count: Int = 20)
    case onDeck
    case recentlyAdded(start: Int = 0, size: Int = 50)
    case search(query: String)

    case scrobble(ratingKey: String)
    case unscrobble(ratingKey: String)
    case timeline(ratingKey: String, state: String, timeMs: Int, durationMs: Int)
    case progress(ratingKey: String, timeMs: Int)
    case history(start: Int = 0, size: Int = 50)

    case stopTranscode(session: String)

    var isPlexTV: Bool {
        switch self {
        case .requestPin, .checkPin, .resources: return true
        default: return false
        }
    }

    static let plexTVBaseURL = URL(string: "https://clients.plex.tv")!

    var method: String {
        switch self {
        case .requestPin:
            return "POST"
        case .stopTranscode:
            return "DELETE"
        default:
            return "GET"
        }
    }

    var path: String {
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
        case .sectionItems(let sectionId, _, _, _, _):
            return "/library/sections/\(sectionId)/all"
        case .sectionGenres(let sectionId):
            return "/library/sections/\(sectionId)/genre"
        case .metadata(let ratingKey):
            return "/library/metadata/\(ratingKey)"
        case .children(let ratingKey):
            return "/library/metadata/\(ratingKey)/children"
        case .hubs:
            return "/hubs"
        case .onDeck:
            return "/library/onDeck"
        case .recentlyAdded:
            return "/library/recentlyAdded"
        case .search:
            return "/hubs/search"
        case .scrobble:
            return "/:/scrobble"
        case .unscrobble:
            return "/:/unscrobble"
        case .timeline:
            return "/:/timeline"
        case .progress:
            return "/:/progress"
        case .history:
            return "/status/sessions/history/all"
        case .stopTranscode:
            return "/video/:/transcode/universal/stop"
        }
    }

    var queryItems: [URLQueryItem]? {
        switch self {
        case .resources:
            return [
                URLQueryItem(name: "includeHttps", value: "1"),
                URLQueryItem(name: "includeRelay", value: "1"),
            ]
        case .sectionItems(_, let sort, let genre, let start, let size):
            var items = [
                URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
                URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)"),
            ]
            if let sort { items.append(URLQueryItem(name: "sort", value: sort)) }
            if let genre { items.append(URLQueryItem(name: "genre", value: genre)) }
            return items
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
        case .history(let start, let size):
            return [
                URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
                URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)"),
            ]
        case .stopTranscode(let session):
            return [URLQueryItem(name: "session", value: session)]
        default:
            return nil
        }
    }

    func urlRequest(baseURL: URL, token: String?) throws -> URLRequest {
        let base = isPlexTV ? Self.plexTVBaseURL : baseURL
        let baseString = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: baseString + path) else {
            throw APIError.invalidURL
        }
        if let queryItems {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method

        for (key, value) in PlexHeaders.allHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if case .requestPin = self {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "strong=true&X-Plex-Product=Crucible&X-Plex-Client-Identifier=\(PlexHeaders.clientIdentifier)".data(using: .utf8)
        }

        return request
    }

}
