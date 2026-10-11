import Foundation

/// A `crucible://` link: `crucible://item/<ratingKey>?type=<movie|show|episode>` opens a detail
/// screen and `crucible://play/<ratingKey>` starts playback. Top Shelf, Siri and in-app shortcuts
/// all produce the same two shapes.
package enum DeepLink: Equatable, Sendable {
    case item(ratingKey: String, mediaType: String?)
    case play(ratingKey: String)

    package static let scheme = "crucible"
    private static let itemTypes: Set<String> = ["movie", "show", "episode"]

    package init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              let ratingKey = Self.ratingKey(from: components.path)
        else { return nil }
        switch host {
        case "item":
            let type = components.queryItems?.first { $0.name == "type" }?.value
            if let type, !Self.itemTypes.contains(type) { return nil }
            self = .item(ratingKey: ratingKey, mediaType: type)
        case "play":
            self = .play(ratingKey: ratingKey)
        default:
            return nil
        }
    }

    package static func isItemType(_ type: String) -> Bool {
        itemTypes.contains(type)
    }

    /// The link in its `crucible://` form, the inverse of `init?(url:)`.
    package var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .item(let ratingKey, let mediaType):
            components.host = "item"
            components.path = "/" + ratingKey
            components.queryItems = mediaType.map { [URLQueryItem(name: "type", value: $0)] }
        case .play(let ratingKey):
            components.host = "play"
            components.path = "/" + ratingKey
        }
        return components.url ?? URL(string: "\(Self.scheme)://")!
    }

    /// Plex rating keys are numeric; anything else would end up verbatim in a server path.
    private static func ratingKey(from path: String) -> String? {
        let key = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return key
    }
}
