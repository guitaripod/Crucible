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
    case secureConnectionFailed

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
        case .secureConnectionFailed:
            return "Could not connect securely to the server. Crucible will re-check your server's address on the next launch."
        }
    }
}

actor APIClient {
    nonisolated let token: String
    private var baseURLStorage: URL
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "com.guitaripod.crucible", category: "api")

    private struct CacheEntry {
        let container: PlexMediaContainer
        let at: Date
    }

    private static let cacheTTL: TimeInterval = 120
    private var containerCache: [String: CacheEntry] = [:]

    /// Current server base URL. Awaitable from anywhere; follows failover repins.
    var baseURL: URL {
        get { baseURLStorage }
    }
    init(baseURL: URL, token: String) {
        self.baseURLStorage = baseURL
        self.token = token
        self.decoder = JSONDecoder()
    }

    /// Called (rarely) when failover repins the server address; reconfigures the URL-derived
    /// singletons so image loads and downloads follow the new route.
    nonisolated static let onBaseURLChanged = OSAllocatedUnfairLock<(@Sendable (URL) -> Void)?>(initialState: nil)

    private func applyFailover(to newURL: URL) {
        guard newURL != baseURLStorage else { return }
        baseURLStorage = newURL
        containerCache.removeAll()
        Self.onBaseURLChanged.withLock { $0 }?(newURL)
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
        let (data, httpResponse) = try await requestRaw(endpoint)
        try Self.validateStatus(httpResponse.statusCode, data: data)
        return try decode(T.self, from: data)
    }

    private func requestRaw(_ endpoint: PlexEndpoint) async throws -> (Data, HTTPURLResponse) {
        let urlRequest = try endpoint.urlRequest(baseURL: baseURL, token: token)
        do {
            return try await Self.performWithRetry { try await Self.send(urlRequest) }
        } catch {
            guard Self.isTransportFailure(error), Self.canAttemptFailover else { throw error }
            try await Self.backoff(attempt: 1)
            return try await failover { try await Self.send(try endpoint.urlRequest(baseURL: $0, token: token)) }
        }
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
        _ = try await requestRaw(endpoint)
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
        await Self.probe(baseURL: baseURL, token: token)
    }

    /// Lightweight reachability probe: `/identity` needs no auth and no TLS pinning.
    nonisolated static func probe(baseURL: URL, token: String) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("/identity"))
        request.timeoutInterval = 6
        for (key, value) in PlexHeaders.allHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (_, httpResponse) = try await send(request)
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

    private static func isTransportFailure(_ error: Error) -> Bool {
        switch error {
        case APIError.timedOut:
            return true
        case let urlError as URLError:
            return transportURLErrorCodes.contains(urlError.code)
        default:
            return false
        }
    }

    private static var canAttemptFailover: Bool {
        KeychainHelper.load(key: "plex_auth_token") != nil
            && UserDefaults.standard.string(forKey: "plex_machine_id") != nil
    }
    private static let transportURLErrorCodes: Set<URLError.Code> = transientURLErrorCodes.union([.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid])

    /// The pinned route died mid-session. Re-discover the server's advertised connections from
    /// plex.tv (the stored token authorizes this), probe them all in parallel, repin the first
    /// reachable one, and replay the failed request against it. Throws the original error when
    /// nothing is reachable so the UI keeps its normal failure path.
    private func failover(
        _ replay: @Sendable (URL) async throws -> (Data, HTTPURLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        logger.error("Transport failure on \(self.baseURLStorage.absoluteString, privacy: .public); attempting failover")
        let candidates = await Self.discoverCandidates(token: token, pinned: baseURL).filter { $0 != baseURL }
        guard let candidate = await ServerConnectionResolver.firstReachable(candidates, token: token) else {
            logger.error("Failover found no reachable route; rethrowing")
            AppLogger.error("Failover from \(baseURLStorage.absoluteString) found no reachable route", .networking)
            throw APIError.serverUnavailable
        }
        logger.notice("Failover to \(candidate.absoluteString, privacy: .public)")
        AppLogger.notice("Failover to \(candidate.absoluteString)", .networking)
        ServerBootstrap.repin(uri: candidate)
        applyFailover(to: candidate)
        return try await Self.performWithRetry { try await replay(candidate) }
    }

    /// Stored candidates first (no network beyond the probe), then plex.tv resources.
    static func discoverCandidates(token: String, pinned: URL) async -> [URL] {
        var seen: [URL] = []
        if let stored = ServerBootstrap.connection()?.candidateURIs {
            seen.append(contentsOf: stored)
        }
        if let resources: [PlexResource] = try? await plexTVRequest(.resources, token: token) {
            for resource in resources where resource.provides.contains("server") {
                for connection in resource.connections {
                    if let url = URL(string: connection.uri), !seen.contains(url) {
                        seen.append(url)
                    }
                }
            }
        }
        return seen.filter { $0 != pinned }
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
