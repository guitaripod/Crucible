import Foundation
import os

enum APIError: Error, LocalizedError, Sendable {
    case invalidURL
    case httpError(statusCode: Int, message: String)
    case decodingError(String)
    case noServerConfigured
    case unauthorized

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
        }
    }
}

actor APIClient {
    nonisolated let baseURL: URL
    nonisolated let token: String
    private let decoder: JSONDecoder

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        self.decoder = JSONDecoder()
    }

    func request<T: Decodable & Sendable>(_ endpoint: PlexEndpoint) async throws -> T {
        let urlRequest = try endpoint.urlRequest(baseURL: baseURL, token: token)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL
        }
        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? "non-utf8"
            Logger(subsystem: "com.guitaripod.crucible", category: "api")
                .error("Decode \(T.self) failed: \(error)\nBody: \(body)")
            throw APIError.decodingError("\(error)\n\nResponse: \(body)")
        }
    }

    func requestContainer(_ endpoint: PlexEndpoint) async throws -> PlexMediaContainer {
        let response: PlexResponse = try await request(endpoint)
        return response.MediaContainer
    }

    func requestVoid(_ endpoint: PlexEndpoint) async throws {
        let urlRequest = try endpoint.urlRequest(baseURL: baseURL, token: token)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL
        }
        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    nonisolated func identityCheck() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("/identity"))
        request.timeoutInterval = 10
        for (key, value) in PlexHeaders.allHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    static func plexTVRequest<T: Decodable & Sendable>(_ endpoint: PlexEndpoint, token: String? = nil) async throws -> T {
        let urlRequest = try endpoint.urlRequest(baseURL: PlexEndpoint.plexTVBaseURL, token: token)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? "non-utf8"
            Logger(subsystem: "com.guitaripod.crucible", category: "api")
                .error("Decode \(T.self) failed: \(error)\nBody: \(body)")
            throw APIError.decodingError(error.localizedDescription)
        }
    }

    static func plexTVRequestVoid(_ endpoint: PlexEndpoint, token: String? = nil) async throws {
        let urlRequest = try endpoint.urlRequest(baseURL: PlexEndpoint.plexTVBaseURL, token: token)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
    }
}
