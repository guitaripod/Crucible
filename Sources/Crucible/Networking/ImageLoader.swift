@preconcurrency import UIKit

actor ImageLoader {
    static let shared = ImageLoader()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 100 * 1024 * 1024
        return c
    }()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func loadImage(path: String, size: String, baseURL: URL) async -> UIImage? {
        let cacheKey = "\(size)/\(path)"
        let nsKey = cacheKey as NSString

        if let cached = cache.object(forKey: nsKey) {
            return cached
        }

        if let existing = inFlight[cacheKey] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> {
            defer { inFlight[cacheKey] = nil }
            var components = URLComponents(url: baseURL.appendingPathComponent("/api/metadata/image/\(path)"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "size", value: size)]
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
