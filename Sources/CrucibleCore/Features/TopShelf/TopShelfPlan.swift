import Foundation

/// The deep links a Top Shelf tile opens: `crucible://play/<ratingKey>` starts playback and
/// `crucible://item/<ratingKey>?type=<type>` opens the detail screen.
package enum TopShelfLink: Equatable, Sendable {
    package static let scheme = "crucible"

    case play(ratingKey: String)
    case item(ratingKey: String, type: String?)

    package var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .play(let ratingKey):
            components.host = "play"
            components.path = "/" + ratingKey
        case .item(let ratingKey, let type):
            components.host = "item"
            components.path = "/" + ratingKey
            components.queryItems = type.map { [URLQueryItem(name: "type", value: $0)] }
        }
        return components.url ?? URL(string: "\(Self.scheme)://")!
    }

    package init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let ratingKey = String(components.path.dropFirst())
        guard components.path.hasPrefix("/"), !ratingKey.isEmpty, !ratingKey.contains("/") else { return nil }
        switch components.host?.lowercased() {
        case "play":
            self = .play(ratingKey: ratingKey)
        case "item":
            let type = components.queryItems?.first { $0.name == "type" }?.value
            self = .item(ratingKey: ratingKey, type: type)
        default:
            return nil
        }
    }
}

/// What the Top Shelf extension shows, in plain values: one row of sections, each tile with its
/// artwork, progress and the two URLs it opens. `nil` means "nothing to show", so the system
/// falls back to the static branded image.
package struct TopShelfPlan: Equatable, Sendable {
    package struct Item: Equatable, Sendable {
        package let identifier: String
        package let title: String
        package let imageURL: URL?
        package let progress: Double?
        package let playURL: URL?
        package let displayURL: URL
    }

    package struct Section: Equatable, Sendable {
        package let title: String
        package let items: [Item]
    }

    package let sections: [Section]

    package init?(snapshot: TopShelfSnapshot?) {
        guard let snapshot, snapshot.schema == TopShelfSnapshot.schemaVersion else { return nil }
        let sections = snapshot.sections
            .map { section in Section(title: section.title, items: section.items.map(Self.item(from:))) }
            .filter { !$0.items.isEmpty }
        guard !sections.isEmpty else { return nil }
        self.sections = sections
    }

    private static func item(from item: TopShelfItem) -> Item {
        Item(
            identifier: item.ratingKey,
            title: item.title,
            imageURL: item.imageURL,
            progress: item.progress,
            playURL: isPlayable(type: item.type) ? TopShelfLink.play(ratingKey: item.ratingKey).url : nil,
            displayURL: TopShelfLink.item(ratingKey: item.ratingKey, type: item.type).url
        )
    }

    private static func isPlayable(type: String) -> Bool {
        type == "movie" || type == "episode" || type == "clip"
    }
}
