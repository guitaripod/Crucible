import Foundation

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

enum APIEndpoint: Sendable {
    case listMovies(page: Int = 1, perPage: Int = 50, sort: String = "title", genre: String? = nil)
    case getMovie(id: String)
    case listShows(page: Int = 1, perPage: Int = 50, sort: String = "name")
    case getShow(id: String)
    case getSeasonEpisodes(showId: String, season: Int)
    case nextEpisode(showId: String)
    case getEpisode(id: String)
    case continueWatching(perPage: Int = 20)
    case onDeck(perPage: Int = 20)
    case recentlyWatched(perPage: Int = 20)
    case recentItems(perPage: Int = 20)
    case listGenres
    case randomItem(mediaType: String? = nil)
    case search(query: String)

    case getPlaybackState(id: String)
    case updatePlaybackState(id: String, body: UpdatePlaybackRequest)
    case markWatched(id: String)
    case markUnwatched(id: String)
    case markShowWatched(showId: String)
    case markShowUnwatched(showId: String)
    case markSeasonWatched(showId: String, season: Int)
    case markSeasonUnwatched(showId: String, season: Int)
    case activityHistory(mediaId: String? = nil, limit: Int = 50, offset: Int = 0)

    case streamInfo(id: String)
    case hlsPrepare(id: String, body: HlsPrepareRequest? = nil)
    case hlsCancel(id: String)
    case hlsStatus(id: String)

    case triggerScan
    case triggerRefresh

    case health
    case stats
    case config
    case scanStatus

    var method: HTTPMethod {
        switch self {
        case .listMovies, .getMovie, .listShows, .getShow, .getSeasonEpisodes,
             .nextEpisode, .getEpisode, .continueWatching, .onDeck,
             .recentlyWatched, .recentItems, .listGenres, .randomItem, .search,
             .getPlaybackState, .activityHistory,
             .streamInfo, .hlsStatus,
             .health, .stats, .config, .scanStatus:
            return .get
        case .markWatched, .markShowWatched, .markSeasonWatched,
             .hlsPrepare, .hlsCancel, .triggerScan, .triggerRefresh:
            return .post
        case .updatePlaybackState:
            return .put
        case .markUnwatched, .markShowUnwatched, .markSeasonUnwatched:
            return .delete
        }
    }

    var path: String {
        switch self {
        case .listMovies: return "/api/library/movies"
        case .getMovie(let id): return "/api/library/movies/\(id)"
        case .listShows: return "/api/library/shows"
        case .getShow(let id): return "/api/library/shows/\(id)"
        case .getSeasonEpisodes(let showId, let season): return "/api/library/shows/\(showId)/seasons/\(season)"
        case .nextEpisode(let showId): return "/api/library/shows/\(showId)/next"
        case .getEpisode(let id): return "/api/library/episodes/\(id)"
        case .continueWatching: return "/api/library/continue"
        case .onDeck: return "/api/library/ondeck"
        case .recentlyWatched: return "/api/library/watched"
        case .recentItems: return "/api/library/recent"
        case .listGenres: return "/api/library/genres"
        case .randomItem: return "/api/library/random"
        case .search: return "/api/library/search"
        case .getPlaybackState(let id): return "/api/playback/\(id)/state"
        case .updatePlaybackState(let id, _): return "/api/playback/\(id)/state"
        case .markWatched(let id): return "/api/playback/\(id)/watched"
        case .markUnwatched(let id): return "/api/playback/\(id)/watched"
        case .markShowWatched(let showId): return "/api/playback/shows/\(showId)/watched"
        case .markShowUnwatched(let showId): return "/api/playback/shows/\(showId)/watched"
        case .markSeasonWatched(let showId, let season): return "/api/playback/shows/\(showId)/seasons/\(season)/watched"
        case .markSeasonUnwatched(let showId, let season): return "/api/playback/shows/\(showId)/seasons/\(season)/watched"
        case .activityHistory: return "/api/playback/history"
        case .streamInfo(let id): return "/api/stream/\(id)/info"
        case .hlsPrepare(let id, _): return "/api/stream/\(id)/hls/prepare"
        case .hlsCancel(let id): return "/api/stream/\(id)/hls/cancel"
        case .hlsStatus(let id): return "/api/stream/\(id)/hls/status"
        case .triggerScan: return "/api/metadata/scan"
        case .triggerRefresh: return "/api/metadata/refresh"
        case .health: return "/api/system/health"
        case .stats: return "/api/system/stats"
        case .config: return "/api/system/config"
        case .scanStatus: return "/api/system/scan-status"
        }
    }

    var queryItems: [URLQueryItem]? {
        switch self {
        case .listMovies(let page, let perPage, let sort, let genre):
            var items = [
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "per_page", value: "\(perPage)"),
                URLQueryItem(name: "sort", value: sort),
            ]
            if let genre { items.append(URLQueryItem(name: "genre", value: genre)) }
            return items
        case .listShows(let page, let perPage, let sort):
            return [
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "per_page", value: "\(perPage)"),
                URLQueryItem(name: "sort", value: sort),
            ]
        case .continueWatching(let perPage), .onDeck(let perPage),
             .recentlyWatched(let perPage), .recentItems(let perPage):
            return [URLQueryItem(name: "per_page", value: "\(perPage)")]
        case .randomItem(let mediaType):
            if let mediaType { return [URLQueryItem(name: "media_type", value: mediaType)] }
            return nil
        case .search(let query):
            return [URLQueryItem(name: "q", value: query)]
        case .activityHistory(let mediaId, let limit, let offset):
            var items = [
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "offset", value: "\(offset)"),
            ]
            if let mediaId { items.append(URLQueryItem(name: "media_id", value: mediaId)) }
            return items
        default:
            return nil
        }
    }

    var body: (any Encodable & Sendable)? {
        switch self {
        case .updatePlaybackState(_, let body): return body
        case .hlsPrepare(_, let body): return body
        default: return nil
        }
    }

    func urlRequest(baseURL: URL) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        if let body {
            request.httpBody = try? JSONEncoder.apiEncoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

extension JSONEncoder {
    static let apiEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}
