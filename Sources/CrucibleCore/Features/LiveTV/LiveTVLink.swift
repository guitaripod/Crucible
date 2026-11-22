import Foundation

/// `crucible://livetv` opens Live TV; `crucible://livetv/add?url=<M3U>&guide=<XMLTV>&name=<name>&ua=<user agent>` offers to
/// add a channel playlist, which is how a playlist reaches a device where typing a long address is a chore (an Apple TV,
/// a phone). The app always asks before adding one.
package enum LiveTVLink: Equatable, Sendable {
    case open
    case add(LivePlaylist)

    package init?(url: URL) {
        guard url.scheme?.lowercased() == DeepLink.scheme, url.host?.lowercased() == "livetv",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if path.isEmpty {
            self = .open
            return
        }
        guard path == "add" else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        guard let address = value("url").flatMap(LivePlaylist.address(from:)) else { return nil }
        let guide = value("guide").flatMap(LivePlaylist.address(from:))
        self = .add(LivePlaylist(name: value("name") ?? LivePlaylist.suggestedName(for: address), address: address, guideAddress: guide, userAgent: value("ua")))
    }

    /// The link that adds `playlist` on another device.
    package static func url(adding playlist: LivePlaylist) -> URL? {
        var components = URLComponents()
        components.scheme = DeepLink.scheme
        components.host = "livetv"
        components.path = "/add"
        var items = [URLQueryItem(name: "url", value: playlist.address.absoluteString), URLQueryItem(name: "name", value: playlist.name)]
        if let guide = playlist.guideAddress { items.append(URLQueryItem(name: "guide", value: guide.absoluteString)) }
        if let agent = playlist.userAgent { items.append(URLQueryItem(name: "ua", value: agent)) }
        components.queryItems = items
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "@", with: "%40").replacingOccurrences(of: "/", with: "%2F")
            .replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: "?", with: "%3F")
        return components.url
    }

    package static func == (lhs: LiveTVLink, rhs: LiveTVLink) -> Bool {
        switch (lhs, rhs) {
        case (.open, .open): return true
        case let (.add(a), .add(b)): return a.address == b.address && a.guideAddress == b.guideAddress && a.name == b.name && a.userAgent == b.userAgent
        default: return false
        }
    }
}
