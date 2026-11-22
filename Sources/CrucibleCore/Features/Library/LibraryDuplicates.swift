import Foundation

/// Finds the copies of one title a server lists as separate items: the same film matched twice, or, in a library without an
/// agent, the same video kept as an `.avi` and its `.mp4` remux or in two folders. Copies share a matched guid, or else a
/// title, a year when both have one and a running time within two seconds (half a percent for long ones), so two different
/// videos that only share a name stay apart. The copy shown is the one that plays best: the larger picture, then a
/// container every client plays directly, then the higher bitrate, then the one already started or watched.
package enum LibraryDuplicates {
    /// What a copy is grouped by before running times are compared.
    package static func key(of item: PlexMetadata) -> String? {
        guard !item.id.isEmpty, ["movie", "clip", "video"].contains(item.mediaType) else { return nil }
        if let guid = item.guid, isMatched(guid) { return "g|\(guid)" }
        let title = item.title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !title.isEmpty else { return nil }
        return "t|\(item.mediaType)|\(title)"
    }

    /// Whether two items with the same key are copies of one title.
    package static func areCopies(_ lhs: PlexMetadata, _ rhs: PlexMetadata) -> Bool {
        guard lhs.id != rhs.id, let key = key(of: lhs), key == self.key(of: rhs) else { return false }
        if key.hasPrefix("g|") { return true }
        if let a = lhs.year, let b = rhs.year, a != b { return false }
        guard let a = lhs.duration, let b = rhs.duration, a > 0, b > 0 else { return false }
        let tolerance = max(2000, Double(max(a, b)) * 0.005)
        return Double(abs(a - b)) <= tolerance
    }

    /// Whether `candidate` should be shown instead of `current`.
    package static func outranks(_ candidate: PlexMetadata, _ current: PlexMetadata) -> Bool {
        rank(candidate) > rank(current)
    }

    /// `items` with each title once, in the order its first copy came, showing its best copy.
    package static func folded(_ items: [PlexMetadata]) -> [PlexMetadata] {
        var result: [PlexMetadata] = []
        var slots: [String: [Int]] = [:]
        for item in items {
            guard let key = key(of: item) else {
                result.append(item)
                continue
            }
            if let slot = slots[key]?.first(where: { areCopies(result[$0], item) }) {
                if outranks(item, result[slot]) { result[slot] = item }
            } else {
                slots[key, default: []].append(result.count)
                result.append(item)
            }
        }
        return result
    }

    private static func isMatched(_ guid: String) -> Bool {
        !(guid.hasPrefix("local://") || guid.contains("agents.none") || guid.hasPrefix("com.plexapp.agents.none"))
    }

    private static func rank(_ item: PlexMetadata) -> (Int, Int, Int, Int) {
        let media = item.Media?.first
        let height = media?.height ?? 0
        let container = switch media?.container?.lowercased() {
        case "mp4", "m4v", "mov": 3
        case "mkv": 2
        case "ts", "webm": 1
        default: 0
        }
        let watched = (item.viewOffset ?? 0) > 0 || (item.viewCount ?? 0) > 0 ? 1 : 0
        return (height, container, media?.bitrate ?? 0, watched)
    }
}
