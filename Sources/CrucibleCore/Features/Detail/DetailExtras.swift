import Foundation

/// The trailers and other clips a title carries, for the shelf under its cast.
package enum DetailExtras {
    /// The clips worth showing, trailers first: each must have something to play.
    package static func items(in item: PlexMetadata) -> [PlexMetadata] {
        let playable = item.extras.filter { !($0.Media ?? []).isEmpty }
        return playable.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (rank(lhs.element), rank(rhs.element))
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    private static func rank(_ extra: PlexMetadata) -> Int {
        extra.subtype == "trailer" ? 0 : 1
    }

    package static let title = String(localized: "Trailers & Extras", comment: "Title of the shelf of trailers and other clips on a detail screen")

    /// What kind of clip it is, in the viewer's words.
    package static func kindName(_ extra: PlexMetadata) -> String {
        switch extra.subtype {
        case "trailer": return String(localized: "Trailer", comment: "Kind of extra: a trailer")
        case "behindTheScenes": return String(localized: "Behind the Scenes", comment: "Kind of extra")
        case "deletedScene": return String(localized: "Deleted Scene", comment: "Kind of extra")
        case "featurette": return String(localized: "Featurette", comment: "Kind of extra: a short documentary about the making")
        case "interview": return String(localized: "Interview", comment: "Kind of extra")
        case "scene", "sceneOrSample": return String(localized: "Scene", comment: "Kind of extra: a clip of a scene")
        case "short": return String(localized: "Short", comment: "Kind of extra: a short film")
        default: return String(localized: "Extra", comment: "Kind of extra when the server did not say")
        }
    }

    /// "Trailer · 2 min": the kind and the length.
    package static func subtitle(_ extra: PlexMetadata) -> String {
        [kindName(extra), DetailFormat.runtime(extra.durationSecs)].compactMap { $0 }.joined(separator: " · ")
    }
}
