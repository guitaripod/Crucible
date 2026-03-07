import Foundation
import os

enum APIError: Error, LocalizedError, Sendable {
    case invalidURL
    case httpError(statusCode: Int, message: String)
    case decodingError(String)
    case noServerConfigured

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
        }
    }
}

actor APIClient {
    nonisolated let baseURL: URL
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL) {
        self.baseURL = baseURL
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    func request<T: Decodable & Sendable>(_ endpoint: APIEndpoint) async throws -> T {
        let urlRequest = try endpoint.urlRequest(baseURL: baseURL)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL
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
            throw APIError.decodingError(error.localizedDescription)
        }
    }

    func requestVoid(_ endpoint: APIEndpoint) async throws {
        let urlRequest = try endpoint.urlRequest(baseURL: baseURL)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    nonisolated func healthCheck() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/system/health"))
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
