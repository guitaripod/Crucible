import CrucibleCore
import CrucibleUI
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Kiln
import MidgarCore

/// Artwork from the connected Plex server through its photo transcoder, sized for where it is drawn: posters up to 720
/// pixels wide and backdrops up to the screen, as `TVImagePipeline` caps them.
@MainActor
final class PlexArtworkPipeline: ArtworkPipeline {
    private let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func url(path: String, kind: CrucibleUI.ArtworkKind, pixelWidth: Int) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
        let ceiling = kind == .poster ? 720 : 3840
        let width = max(64, min(pixelWidth, ceiling))
        let height = kind == .poster ? Int(Double(width) * 1.5) : Int(Double(width) * 0.5625)
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: base + "/photo/:/transcode") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "width", value: "\(width)"),
            URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "minSize", value: "1"),
        ]
        return components.url
    }

    /// Fetches artwork with the Plex headers (the token travels as a header, never in the cached URL).
    static func fetcher(token: String) -> ImageStore.Fetch {
        { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            if url.host.map({ !$0.hasSuffix("plex.tv") && !$0.hasSuffix("image.tmdb.org") }) ?? true {
                for (key, value) in PlexHeaders.allHeaders(token: token) { request.setValue(value, forHTTPHeaderField: key) }
            }
            let (data, response) = try await HTTPSession.current.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
            return data
        }
    }
}
