@preconcurrency import UIKit
import os

actor ImageLoader {
    static let shared = ImageLoader()

    private struct Config: Sendable {
        let baseURL: URL
        let token: String
        let machineIdentifier: String
    }

    private let config = OSAllocatedUnfairLock<Config?>(initialState: nil)
    private let logger = Logger(subsystem: "com.guitaripod.crucible", category: "image")

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 100 * 1024 * 1024
        return c
    }()
    private var inFlight: [String: (token: Int, task: Task<UIImage?, Never>)] = [:]
    private var inFlightCounter = 0
    private var disk: DiskImageCache?
    private var diskNamespace: String?

    nonisolated func configure(baseURL: URL, token: String, machineIdentifier: String) {
        config.withLock { $0 = Config(baseURL: baseURL, token: token, machineIdentifier: machineIdentifier) }
        Task { await self.cancelInFlight() }
    }

    private func cancelInFlight() {
        for entry in inFlight.values {
            entry.task.cancel()
        }
        inFlight.removeAll()
    }

    /// Returns the disk tier for the active server, rebuilding it when the server changes.
    private func diskCache(namespace: String) -> DiskImageCache {
        if diskNamespace != namespace || disk == nil {
            disk = DiskImageCache(namespace: namespace)
            diskNamespace = namespace
        }
        return disk!
    }

    func clearCache() {
        cache.removeAllObjects()
        disk?.clear()
    }

    func loadImage(path: String, width: Int) async -> UIImage? {
        await load(path: path, width: width, height: Int(Double(width) * 1.5), prefix: "p")
    }

    func loadBackdrop(path: String, width: Int) async -> UIImage? {
        await load(path: path, width: width, height: Int(Double(width) * 0.56), prefix: "b")
    }

    private func load(path: String, width: Int, height: Int, prefix: String) async -> UIImage? {
        guard let config = config.withLock({ $0 }) else { return nil }
        let diskKey = "\(prefix)\(width)/\(path)"
        let cacheKey = "\(config.machineIdentifier)/\(diskKey)"
        let nsKey = cacheKey as NSString

        if let cached = cache.object(forKey: nsKey) {
            return cached
        }

        if let existing = inFlight[cacheKey] {
            return await existing.task.value
        }

        let disk = diskCache(namespace: config.machineIdentifier)
        inFlightCounter &+= 1
        let token = inFlightCounter

        let task = Task<UIImage?, Never> {
            defer { if inFlight[cacheKey]?.token == token { inFlight[cacheKey] = nil } }

            if let cached = await disk.read(key: diskKey), let image = await Self.prepare(cached) {
                cache.setObject(image, forKey: nsKey, cost: Self.cost(of: image))
                return image
            }

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
                guard let image = await Self.prepare(data) else {
                    logger.error("Image request \(path, privacy: .public) returned undecodable data")
                    return nil
                }
                disk.write(data, key: diskKey)
                cache.setObject(image, forKey: nsKey, cost: Self.cost(of: image))
                return image
            } catch {
                logger.debug("Image request \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        inFlight[cacheKey] = (token, task)
        return await task.value
    }

    private static func prepare(_ data: Data) async -> UIImage? {
        guard let decoded = UIImage(data: data) else { return nil }
        return await decoded.byPreparingForDisplay() ?? decoded
    }

    private static func cost(of image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height }
            ?? Int(image.size.width * image.scale) * Int(image.size.height * image.scale) * 4
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
