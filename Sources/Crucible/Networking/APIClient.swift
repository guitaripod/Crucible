import Foundation
import os

enum APIError: Error, LocalizedError, Sendable {
    case invalidURL
    case httpError(statusCode: Int, message: String)
    case decodingError(String)
    case noServerConfigured
    case unauthorized
    case rateLimited
    case serverUnavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .httpError(let code, let message):
            return "HTTP \(code): \(message)"
        case .decodingError(let detail):
            return "Decoding error: \(detail)"
        case .noServerConfigured:
            return "No server configured"
        case .unauthorized:
            return "Authentication expired. Please sign in again."
        case .rateLimited:
            return "The server is rate limiting requests. Please try again shortly."
        case .serverUnavailable:
            return "The server is temporarily unavailable. Please try again shortly."
        case .timedOut:
            return "The request timed out. Please check your connection and try again."
        }
    }
}

actor APIClient {
    nonisolated let baseURL: URL
    nonisolated let token: String
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "com.guitaripod.crucible", category: "api")

    private struct CacheEntry {
        let container: PlexMediaContainer
        let at: Date
    }

    private static let cacheTTL: TimeInterval = 120
    private var containerCache: [String: CacheEntry] = [:]

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        self.decoder = JSONDecoder()
    }

    func invalidateCache() {
        containerCache.removeAll()
    }

    func invalidate(ratingKey: String) {
        let paths = [
            PlexEndpoint.metadata(ratingKey: ratingKey).path,
            PlexEndpoint.children(ratingKey: ratingKey).path,
        ]
        for path in paths {
            containerCache.removeValue(forKey: path)
        }
    }

    func request<T: Decodable & Sendable>(_ endpoint: PlexEndpoint) async throws -> T {
        let urlRequest = try endpoint.urlRequest(baseURL: baseURL, token: token)
        let (data, httpResponse) = try await Self.performWithRetry { try await Self.send(urlRequest) }
        try Self.validateStatus(httpResponse.statusCode, data: data)
        return try decode(T.self, from: data)
    }

    func requestContainer(_ endpoint: PlexEndpoint) async throws -> PlexMediaContainer {
        if let key = Self.cacheKey(for: endpoint), let cached = cachedContainer(forKey: key) {
            return cached
        }
        let response: PlexResponse = try await request(endpoint)
        let container = response.MediaContainer
        if let key = Self.cacheKey(for: endpoint) {
            containerCache[key] = CacheEntry(container: container, at: Date())
        }
        return container
    }

    func requestVoid(_ endpoint: PlexEndpoint) async throws {
        let urlRequest = try endpoint.urlRequest(baseURL: baseURL, token: token)
        let (data, httpResponse) = try await Self.performWithRetry { try await Self.send(urlRequest) }
        try Self.validateStatus(httpResponse.statusCode, data: data)
    }

    private func cachedContainer(forKey key: String) -> PlexMediaContainer? {
        guard let entry = containerCache[key] else { return nil }
        if Date().timeIntervalSince(entry.at) > Self.cacheTTL {
            containerCache.removeValue(forKey: key)
            return nil
        }
        return entry.container
    }

    private static func cacheKey(for endpoint: PlexEndpoint) -> String? {
        switch endpoint {
        case .metadata, .children:
            return endpoint.path
        default:
            return nil
        }
    }

    private func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.error("Decode \(T.self, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            logger.debug("Decode body: \(String(data: data.prefix(500), encoding: .utf8) ?? "non-utf8", privacy: .private)")
            let body = String(data: data.prefix(280), encoding: .utf8) ?? "non-utf8"
            AppLogger.error("Decode \(T.self) failed: \(String(describing: error)) | body: \(body)", .networking)
            throw APIError.decodingError(error.localizedDescription)
        }
    }

    nonisolated func identityCheck() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("/identity"))
        request.timeoutInterval = 10
        for (key, value) in PlexHeaders.allHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (_, httpResponse) = try await Self.send(request)
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    static func plexTVRequest<T: Decodable & Sendable>(_ endpoint: PlexEndpoint, token: String? = nil) async throws -> T {
        let urlRequest = try endpoint.urlRequest(baseURL: PlexEndpoint.plexTVBaseURL, token: token)
        let (data, httpResponse) = try await performWithRetry { try await send(urlRequest) }
        try validateStatus(httpResponse.statusCode, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Logger(subsystem: "com.guitaripod.crucible", category: "api")
                .error("Decode \(T.self, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw APIError.decodingError(error.localizedDescription)
        }
    }

    static func plexTVRequestVoid(_ endpoint: PlexEndpoint, token: String? = nil) async throws {
        let urlRequest = try endpoint.urlRequest(baseURL: PlexEndpoint.plexTVBaseURL, token: token)
        let (data, httpResponse) = try await performWithRetry { try await send(urlRequest) }
        try validateStatus(httpResponse.statusCode, data: data)
    }

    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidURL
            }
            return (data, httpResponse)
        } catch let error as URLError where error.code == .timedOut {
            throw APIError.timedOut
        }
    }

    private static func validateStatus(_ statusCode: Int, data: Data) throws {
        if statusCode == 401 {
            throw APIError.unauthorized
        }
        if statusCode == 429 {
            throw APIError.rateLimited
        }
        if (500...599).contains(statusCode) {
            throw APIError.serverUnavailable
        }
        guard (200...299).contains(statusCode) else {
            throw APIError.httpError(statusCode: statusCode, message: Self.reason(for: statusCode))
        }
    }

    private static func reason(for statusCode: Int) -> String {
        HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
    }

    private static let maxRetries = 3
    private static let baseBackoff: TimeInterval = 0.5
    private static let maxBackoff: TimeInterval = 4

    private static func performWithRetry(
        _ operation: () async throws -> (Data, HTTPURLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                let (data, httpResponse) = try await operation()
                if attempt < maxRetries, isTransient(statusCode: httpResponse.statusCode) {
                    attempt += 1
                    try await backoff(attempt: attempt)
                    continue
                }
                return (data, httpResponse)
            } catch {
                guard attempt < maxRetries, isTransient(error: error) else { throw error }
                attempt += 1
                try await backoff(attempt: attempt)
            }
        }
    }

    private static func isTransient(statusCode: Int) -> Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }

    private static func isTransient(error: Error) -> Bool {
        switch error {
        case APIError.rateLimited, APIError.serverUnavailable, APIError.timedOut:
            return true
        case let urlError as URLError:
            return transientURLErrorCodes.contains(urlError.code)
        default:
            return false
        }
    }

    private static let transientURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotConnectToHost,
        .networkConnectionLost,
        .notConnectedToInternet,
        .dnsLookupFailed,
        .cannotFindHost,
    ]

    private static func backoff(attempt: Int) async throws {
        let exponential = baseBackoff * pow(2, Double(attempt - 1))
        let capped = min(exponential, maxBackoff)
        let jitter = Double.random(in: 0...(capped / 2))
        let delay = capped + jitter
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
}
