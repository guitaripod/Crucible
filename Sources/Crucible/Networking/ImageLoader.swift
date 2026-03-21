@preconcurrency import UIKit

actor ImageLoader {
    static let shared = ImageLoader()

    private var baseURL: URL?
    private var token: String?

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 100 * 1024 * 1024
        return c
    }()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func configure(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    func loadImage(path: String, width: Int) async -> UIImage? {
        guard let baseURL, let token else { return nil }
        let cacheKey = "\(width)/\(path)"
        let nsKey = cacheKey as NSString

        if let cached = cache.object(forKey: nsKey) {
            return cached
        }

        if let existing = inFlight[cacheKey] {
            return await existing.value
        }

        let capturedBaseURL = baseURL
        let capturedToken = token
        let task = Task<UIImage?, Never> {
            defer { inFlight[cacheKey] = nil }
            var components = URLComponents(url: capturedBaseURL.appendingPathComponent("/photo/:/transcode"), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "url", value: path),
                URLQueryItem(name: "width", value: "\(width)"),
                URLQueryItem(name: "height", value: "\(Int(Double(width) * 1.5))"),
                URLQueryItem(name: "minSize", value: "1"),
                URLQueryItem(name: "X-Plex-Token", value: capturedToken),
            ]
            guard let url = components?.url else { return nil }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = UIImage(data: data) else { return nil }
                let cost = data.count
                cache.setObject(image, forKey: nsKey, cost: cost)
                return image
            } catch {
                return nil
            }
        }

        inFlight[cacheKey] = task
        return await task.value
    }

    func loadBackdrop(path: String, width: Int) async -> UIImage? {
        guard let baseURL, let token else { return nil }
        let cacheKey = "bd\(width)/\(path)"
        let nsKey = cacheKey as NSString

        if let cached = cache.object(forKey: nsKey) {
            return cached
        }

        if let existing = inFlight[cacheKey] {
            return await existing.value
        }

        let capturedBaseURL = baseURL
        let capturedToken = token
        let task = Task<UIImage?, Never> {
            defer { inFlight[cacheKey] = nil }
            var components = URLComponents(url: capturedBaseURL.appendingPathComponent("/photo/:/transcode"), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "url", value: path),
                URLQueryItem(name: "width", value: "\(width)"),
                URLQueryItem(name: "height", value: "\(Int(Double(width) * 0.56))"),
                URLQueryItem(name: "minSize", value: "1"),
                URLQueryItem(name: "X-Plex-Token", value: capturedToken),
            ]
            guard let url = components?.url else { return nil }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = UIImage(data: data) else { return nil }
                let cost = data.count
                cache.setObject(image, forKey: nsKey, cost: cost)
                return image
            } catch {
                return nil
            }
        }

        inFlight[cacheKey] = task
        return await task.value
    }
}
