import UIKit

/// Artwork from a full URL that is not on the Plex server, such as the posters a viewer's own Seerr hands out, kept in memory
/// while the app runs.
package actor RemoteImageLoader {
    package static let shared = RemoteImageLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init() {
        cache.countLimit = 300
    }

    package func image(at url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let running = inFlight[url] { return await running.value }
        let task = Task<UIImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { return nil }
            return await image.byPreparingForDisplay() ?? image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}
