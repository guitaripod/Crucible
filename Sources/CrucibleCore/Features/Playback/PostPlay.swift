import Foundation
import MidgarCore

/// What waits on screen once a movie, or the last episode of a show, has ended and nothing plays next: the titles the server
/// finds like it, the ones still to watch first. A movie picked there plays in the same player; a show opens its screen.
package enum PostPlay {
    package static let limit = 8

    /// The title whose related titles are offered: the movie itself, or the show an episode belongs to. A playlist ends where
    /// its owner ended it, and nothing else has related titles worth offering.
    package static func subjectKey(for request: PlaybackRequest) -> String? {
        guard request.queue == nil, request.offline == nil else { return nil }
        switch request.mediaType {
        case "movie": return request.ratingKey
        case "episode": return request.showRatingKey
        default: return nil
        }
    }

    /// The suggestions for what just ended, or none when the setting is off, there is nothing to ask about, the server has
    /// nothing like it or does not answer within `timeout`: the player is waiting on them, so a slow server must not keep it up.
    package static func suggestions(for request: PlaybackRequest, api: APIClient, timeout: Duration = .seconds(5)) async -> [PlexMetadata] {
        guard Preferences.postPlaySuggestions, let key = subjectKey(for: request) else { return [] }
        return await withTaskGroup(of: [PlexMetadata]?.self) { group in
            group.addTask { await fetch(subjectKey: key, playing: request.ratingKey, api: api) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    private static func fetch(subjectKey key: String, playing ratingKey: String, api: APIClient) async -> [PlexMetadata] {
        do {
            guard let subject = try await api.requestContainer(.metadata(ratingKey: key)).Metadata?.first else { return [] }
            return ordered(DetailRelated.items(in: subject), excluding: [ratingKey, key])
        } catch {
            MidgarLog.notice("Post-play suggestions for \(key) failed: \(error.localizedDescription)", category: .playback)
            return []
        }
    }

    /// Movies and shows only, the ones still to watch first, each group in the server's order.
    package static func ordered(_ items: [PlexMetadata], excluding keys: Set<String> = [], limit: Int = limit) -> [PlexMetadata] {
        let playable = items.filter { ($0.mediaType == "movie" || $0.mediaType == "show") && !keys.contains($0.id) }
        let fresh = playable.filter { !isSeen($0) }
        let seen = playable.filter(isSeen)
        return Array((fresh + seen).prefix(limit))
    }

    /// A movie watched at least once, or a show with every episode watched.
    package static func isSeen(_ item: PlexMetadata) -> Bool {
        if item.mediaType == "show" {
            guard let leaves = item.leafCount, leaves > 0 else { return false }
            return (item.viewedLeafCount ?? 0) >= leaves
        }
        return item.isWatched
    }

    /// What the screen is called: named after the movie or show that just ended.
    package static func heading(for request: PlaybackRequest) -> String {
        heading(after: request.metadata.map { $0.showName ?? $0.title })
    }

    package static func heading(after title: String?) -> String {
        guard let title, !title.isEmpty else { return String(localized: "More Like This") }
        return String(localized: "Because You Watched \(title)", comment: "Heading over titles suggested when a movie or show ends; the argument is its title")
    }

    /// What picking a suggestion does, said under its title for VoiceOver.
    package static func hint(for item: PlexMetadata) -> String {
        item.mediaType == "show"
            ? String(localized: "Opens the show", comment: "VoiceOver hint of a suggested show at the end of playback")
            : String(localized: "Plays the movie", comment: "VoiceOver hint of a suggested movie at the end of playback")
    }

    package static var closeTitle: String { String(localized: "Close", comment: "Button that closes the player at the end of playback") }
}
