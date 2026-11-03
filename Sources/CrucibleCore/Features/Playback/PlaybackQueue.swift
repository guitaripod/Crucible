import Foundation

/// An ordered list of titles to play one after the other, such as a playlist: what follows the item playing is the next entry, not the next
/// episode of a season.
package struct PlaybackQueue: Sendable, Equatable {
    package let entries: [PlexMetadata]
    package let position: Int

    package init?(entries: [PlexMetadata], position: Int = 0) {
        guard entries.indices.contains(position) else { return nil }
        self.entries = entries
        self.position = position
    }

    /// Films and episodes, the entries a player can play.
    package static func isPlayable(_ entry: PlexMetadata) -> Bool {
        entry.mediaType == "movie" || entry.mediaType == "episode"
    }

    /// The playable entries of `entries` in order, standing on `entry` or on the first one.
    package static func starting(at entry: PlexMetadata? = nil, in entries: [PlexMetadata]) -> PlaybackQueue? {
        let playable = entries.filter(isPlayable)
        let index = entry.flatMap { chosen in playable.firstIndex { $0.entryID == chosen.entryID } } ?? 0
        return PlaybackQueue(entries: playable, position: index)
    }

    /// The playable entries of `entries` in a random order.
    package static func shuffled(_ entries: [PlexMetadata], using generator: inout some RandomNumberGenerator) -> PlaybackQueue? {
        PlaybackQueue(entries: entries.filter(isPlayable).shuffled(using: &generator))
    }

    package static func shuffled(_ entries: [PlexMetadata]) -> PlaybackQueue? {
        var generator = SystemRandomNumberGenerator()
        return shuffled(entries, using: &generator)
    }

    package var current: PlexMetadata { entries[position] }

    package var hasNext: Bool { position + 1 < entries.count }

    /// The queue standing on the next entry, or nil at the last one.
    package func advanced() -> PlaybackQueue? {
        hasNext ? PlaybackQueue(entries: entries, position: position + 1) : nil
    }
}
