import Foundation

/// The Seerr routes Crucible uses, under `/api/v1` of the address the viewer connected.
package enum SeerrEndpoint: Sendable, Equatable {
    case status
    case publicSettings
    case signInWithPlex(token: String)
    case me
    case signOut
    case movie(tmdbID: Int)
    case show(tmdbID: Int)
    case createRequest(kind: SeerrMediaKind, tmdbID: Int, tvdbID: Int?, seasons: [Int]?)
    case requests(take: Int, skip: Int, filter: String, requestedBy: Int?)
    case cancelRequest(id: Int)
    case moderate(id: Int, approve: Bool)
    case retry(id: Int)
    case quota(userID: Int)
    case search(query: String)

    package var method: String {
        switch self {
        case .signInWithPlex, .signOut, .createRequest, .moderate, .retry: return "POST"
        case .cancelRequest: return "DELETE"
        default: return "GET"
        }
    }

    package var path: String {
        switch self {
        case .status: return "status"
        case .publicSettings: return "settings/public"
        case .signInWithPlex: return "auth/plex"
        case .me: return "auth/me"
        case .signOut: return "auth/logout"
        case .movie(let id): return "movie/\(id)"
        case .show(let id): return "tv/\(id)"
        case .createRequest, .requests: return "request"
        case .cancelRequest(let id): return "request/\(id)"
        case .moderate(let id, let approve): return "request/\(id)/\(approve ? "approve" : "decline")"
        case .retry(let id): return "request/\(id)/retry"
        case .quota(let id): return "user/\(id)/quota"
        case .search: return "search"
        }
    }

    /// Routes anyone may call: they need no session, and a refusal there says nothing about the viewer's sign-in.
    package var isPublic: Bool {
        switch self {
        case .status, .publicSettings, .signInWithPlex: return true
        default: return false
        }
    }

    package var queryItems: [URLQueryItem] {
        switch self {
        case .requests(let take, let skip, let filter, let requestedBy):
            var items = [
                URLQueryItem(name: "take", value: "\(take)"),
                URLQueryItem(name: "skip", value: "\(skip)"),
                URLQueryItem(name: "filter", value: filter),
                URLQueryItem(name: "sort", value: "modified"),
            ]
            if let requestedBy { items.append(URLQueryItem(name: "requestedBy", value: "\(requestedBy)")) }
            return items
        case .status:
            return [URLQueryItem(name: "checkUpdateAvailable", value: "false")]
        case .search(let query):
            return [URLQueryItem(name: "query", value: query), URLQueryItem(name: "page", value: "1")]
        default:
            return []
        }
    }

    package var body: Data? {
        switch self {
        case .signInWithPlex(let token):
            return try? JSONSerialization.data(withJSONObject: ["authToken": token])
        case .createRequest(let kind, let tmdbID, let tvdbID, let seasons):
            var object: [String: Any] = ["mediaType": kind.rawValue, "mediaId": tmdbID, "is4k": false]
            if let tvdbID { object["tvdbId"] = tvdbID }
            if kind == .tv { object["seasons"] = seasons.map { $0 as Any } ?? "all" }
            return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        default:
            return nil
        }
    }

    /// The URL of this route under `base`, which may carry a path of its own when Seerr sits behind a reverse proxy.
    package func url(base: URL) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent("api/v1/" + path), resolvingAgainstBaseURL: false)
        let items = queryItems
        components?.queryItems = items.isEmpty ? nil : items
        return components?.url
    }
}

/// Artwork Seerr fetches from TMDB on the server's behalf, so the device asks only the viewer's own Seerr.
package enum SeerrImage {
    package static func poster(_ path: String?, base: URL) -> URL? {
        image(path, size: "w342", base: base)
    }

    package static func backdrop(_ path: String?, base: URL) -> URL? {
        image(path, size: "w1280", base: base)
    }

    private static func image(_ path: String?, size: String, base: URL) -> URL? {
        guard let path, path.hasPrefix("/"), !path.contains("://") else { return nil }
        return base.appendingPathComponent("imageproxy/tmdb/t/p/\(size)" + path)
    }
}
