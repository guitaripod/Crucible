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
        await load(path: path, width: width, height: Int(Double(width) * 1.5), prefix: "p")
    }

    func loadBackdrop(path: String, width: Int) async -> UIImage? {
        await load(path: path, width: width, height: Int(Double(width) * 0.56), prefix: "b")
    }

    private func load(path: String, width: Int, height: Int, prefix: String) async -> UIImage? {
        guard let baseURL, let token else { return nil }
        let cacheKey = "\(prefix)\(width)/\(path)"
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
            let baseString = capturedBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(baseString)/photo/:/transcode?url=\(path)&width=\(width)&height=\(height)&minSize=1&X-Plex-Token=\(capturedToken)") else { return nil }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = UIImage(data: data) else { return nil }
                cache.setObject(image, forKey: nsKey, cost: data.count)
                return image
            } catch {
                return nil
            }
        }

        inFlight[cacheKey] = task
        return await task.value
    }
}
