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

    /// Fetches artwork, with the Plex headers for the server's own (the token travels as a header, never in the cached URL).
    /// A picture from the web (`WebArtwork`) is fetched apart, without them.
    static func fetcher(token: String) -> ImageStore.Fetch {
        { url in
            if WebArtwork.isWeb(url) { return try await WebArtwork.fetch(url) }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            if isServerArtwork(url) {
                for (key, value) in PlexHeaders.allHeaders(token: token) { request.setValue(value, forHTTPHeaderField: key) }
            }
            let (data, response) = try await HTTPSession.current.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
            return data
        }
    }

    /// Whether `url` is the Plex server's own artwork (its photo transcoder or a library image), the only images that carry
    /// the account's token: Seerr's image proxy, TMDB, plex.tv and every other host never see it.
    nonisolated static func isServerArtwork(_ url: URL) -> Bool {
        guard let host = url.host, !host.hasSuffix("plex.tv"), !host.hasSuffix("image.tmdb.org") else { return false }
        return url.path.hasPrefix("/photo/") || url.path.hasPrefix("/library/")
    }
}
