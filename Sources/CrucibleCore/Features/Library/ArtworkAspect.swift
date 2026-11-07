import Foundation

/// How tall a card's artwork is for its width, read from what the artwork is instead of assuming a poster: films, shows, seasons
/// and collections have 2:3 posters, episodes and extras 16:9 stills, playlists and music square covers, and a personal video (an
/// Other Videos library, a home movie) a frame Plex grabbed from the file, so its thumbnail has the shape of the video itself.
package enum ArtworkAspect {
    package static let poster = 1.5
    package static let still = 9.0 / 16.0
    package static let square = 1.0

    /// The flattest and tallest shapes a grid is laid out in, so a malformed size cannot make a sliver or a tower of a card.
    private static let range = 0.4...1.8

    /// How far apart artwork and card may be for the artwork to fill the card by cropping, as a fraction of the card's shape.
    private static let cropTolerance = 0.1

    /// The shape of `path` drawn for `item`: the item's own thumb or composite has the item's shape, and a parent's or
    /// grandparent's thumb (the show's poster on an episode) is a poster.
    package static func of(_ item: PlexMetadata, path: String?) -> Double {
        guard let path, path == item.thumb || path == item.composite else { return poster }
        return own(item)
    }

    /// The shape most of `aspects` share, so a grid of mixed artwork is laid out in the shape it mostly shows. Shapes within a
    /// hundredth count as one (1280×720 and 1920×1080 frames); a tie goes to the shape seen first, and no artwork is a poster.
    package static func dominant(_ aspects: some Sequence<Double>) -> Double {
        var counts: [Int: (count: Int, aspect: Double)] = [:]
        var order: [Int] = []
        for aspect in aspects {
            let key = Int((aspect * 100).rounded())
            if counts[key] == nil { order.append(key) }
            counts[key, default: (0, aspect)].count += 1
        }
        var best: (count: Int, aspect: Double)?
        for key in order {
            guard let entry = counts[key], entry.count > best?.count ?? 0 else { continue }
            best = entry
        }
        return best.map { min(max($0.aspect, range.lowerBound), range.upperBound) } ?? poster
    }

    /// Whether artwork `imageAspect` tall for its width can fill a card `cardAspect` tall by cropping: within a tenth, as a 27×40
    /// poster in a 2:3 card or a 1.85:1 frame in a 16:9 one. Further apart a crop would cut the picture away, so it is shown whole.
    package static func fills(_ imageAspect: Double, card cardAspect: Double) -> Bool {
        abs(imageAspect - cardAspect) <= cardAspect * cropTolerance
    }

    private static func own(_ item: PlexMetadata) -> Double {
        switch item.mediaType {
        case "playlist", "artist", "album", "track", "photoalbum":
            return square
        case "photo":
            return frame(of: item) ?? square
        case "episode", "clip":
            return item.isPersonalMedia ? frame(of: item) ?? still : still
        case "movie":
            return item.isPersonalMedia ? frame(of: item) ?? still : poster
        default:
            return poster
        }
    }

    /// The video's or picture's own shape, from the first media's pixel size.
    private static func frame(of item: PlexMetadata) -> Double? {
        guard let width = item.Media?.first?.width, let height = item.Media?.first?.height, width > 0, height > 0 else { return nil }
        return Double(height) / Double(width)
    }
}

extension PlexMetadata {
    /// Whether the item belongs to a library without a metadata agent (Plex's Personal Media agent, new or legacy), whose
    /// thumbnails are frames of the file rather than posters or stills.
    package var isPersonalMedia: Bool {
        guard let guid else { return false }
        return guid.hasPrefix("tv.plex.agents.none://") || guid.hasPrefix("com.plexapp.agents.none://")
    }
}
