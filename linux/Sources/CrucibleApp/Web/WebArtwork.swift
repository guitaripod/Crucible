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
