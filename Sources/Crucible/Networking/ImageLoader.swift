@preconcurrency import UIKit
import os

actor ImageLoader {
    static let shared = ImageLoader()

    private struct Config: Sendable {
        let baseURL: URL
        let token: String
    }

    private let config = OSAllocatedUnfairLock<Config?>(initialState: nil)
    private let logger = Logger(subsystem: "com.guitaripod.crucible", category: "image")

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 100 * 1024 * 1024
        return c
    }()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    nonisolated func configure(baseURL: URL, token: String) {
        config.withLock { $0 = Config(baseURL: baseURL, token: token) }
        Task { await self.cancelInFlight() }
    }

    private func cancelInFlight() {
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    func loadImage(path: String, width: Int) async -> UIImage? {
        await load(path: path, width: width, height: Int(Double(width) * 1.5), prefix: "p")
    }

    func loadBackdrop(path: String, width: Int) async -> UIImage? {
        await load(path: path, width: width, height: Int(Double(width) * 0.56), prefix: "b")
    }

    private func load(path: String, width: Int, height: Int, prefix: String) async -> UIImage? {
        guard let config = config.withLock({ $0 }) else { return nil }
        let cacheKey = "\(prefix)\(width)/\(path)"
        let nsKey = cacheKey as NSString

        if let cached = cache.object(forKey: nsKey) {
            return cached
        }

        if let existing = inFlight[cacheKey] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> {
            defer { inFlight[cacheKey] = nil }
            guard let request = imageRequest(config: config, path: path, width: width, height: height) else {
                return nil
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return nil }
                guard http.statusCode == 200 else {
                    logger.error("Image request \(path, privacy: .public) returned HTTP \(http.statusCode)")
                    return nil
                }
                guard let decoded = UIImage(data: data) else {
                    logger.error("Image request \(path, privacy: .public) returned undecodable data")
                    return nil
                }
                let image = await decoded.byPreparingForDisplay() ?? decoded
                cache.setObject(image, forKey: nsKey, cost: data.count)
                return image
            } catch {
                logger.debug("Image request \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        inFlight[cacheKey] = task
        return await task.value
    }

    private func imageRequest(config: Config, path: String, width: Int, height: Int) -> URLRequest? {
        let baseString = config.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: baseString + "/photo/:/transcode") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "width", value: "\(width)"),
            URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "minSize", value: "1"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        for (key, value) in PlexHeaders.allHeaders(token: config.token) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }
}
