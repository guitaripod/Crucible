import CrucibleUI
import CrucibleWeb
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CrucibleCore

/// Pictures from the web (thumbnails, channel pictures, storyboards). Their addresses carry a mark the artwork fetcher
/// reads, so they are fetched as a browser would and never with the Plex account's headers, whatever their host or path.
enum WebArtwork {
    private static let mark = "crucible-web"
    static let userAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    /// The artwork for a card of `entry`: its sharpest thumbnail, with the others to fall back on.
    static func source(for entry: WebEntry) -> ArtworkSource? {
        url(entry.thumbnailCandidates).map(ArtworkSource.url)
    }

    static func source(_ address: String?) -> ArtworkSource? {
        address.flatMap { url([$0]) }.map(ArtworkSource.url)
    }

    /// The inbox card's picture: the 480 pixel thumbnail rather than the 1280 the shelves draw, since a card's artwork is
    /// a fraction of the window and sixty of them arrive at once.
    static func inboxSource(for entry: WebEntry) -> ArtworkSource? {
        let video = WebLink.youTubeVideoID(in: entry.url) ?? (entry.id.count == 11 && entry.url.contains("youtu") ? entry.id : nil)
        guard let video else { return source(for: entry) }
        return url(["https://i.ytimg.com/vi/\(video)/hqdefault.jpg", "https://i.ytimg.com/vi/\(video)/mqdefault.jpg"])
            .map(ArtworkSource.url)
    }

    /// A channel's face at 88 pixels square, where the subscriptions list keeps its 900 pixel picture, for the small rounds
    /// beside an inbox card's channel.
    static func avatar(_ address: String?) -> ArtworkSource? {
        guard let address, address.contains("yt3.googleusercontent.com"),
              let suffix = address.range(of: "=s", options: .backwards) else { return source(address) }
        return url([String(address[..<suffix.lowerBound]) + "=s88-c-k-c0x00ffffff-no-rj"]).map(ArtworkSource.url)
    }

    /// One marked address standing for `candidates`: the first one, with the rest in its fragment to try when it is
    /// missing.
    static func url(_ candidates: [String]) -> URL? {
        guard let first = candidates.first, var components = URLComponents(string: first) else { return nil }
        let rest = candidates.dropFirst().compactMap { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) }
        components.fragment = ([mark] + rest).joined(separator: ",")
        return components.url
    }

    /// The artwork a poster path names: a marked web address is fetched as it is, anything else is the server's.
    static func poster(_ path: String) -> ArtworkSource {
        if let url = URL(string: path), isWeb(url) { return .url(url) }
        return .path(path, .poster)
    }

    static func isWeb(_ url: URL) -> Bool {
        url.fragment?.hasPrefix(mark) ?? false
    }

    /// Fetches a marked address, trying each of its candidates in turn.
    static func fetch(_ url: URL) async throws -> Data {
        var candidates: [URL] = []
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let rest = (components.fragment ?? "").split(separator: ",").dropFirst().compactMap { String($0).removingPercentEncoding }
            components.fragment = nil
            if let first = components.url { candidates.append(first) }
            candidates += rest.compactMap(URL.init(string:))
        }
        var failure: Error = URLError(.badURL)
        for candidate in candidates {
            do {
                return try await data(from: candidate)
            } catch {
                failure = error
            }
        }
        throw failure
    }

    /// Fetches `url` as a browser would: its user agent and nothing of the viewer's.
    static func data(from url: URL, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTPSession.current.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
